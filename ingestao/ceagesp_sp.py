#!/usr/bin/env python3
"""
Coletor das cotacoes do Entreposto da Capital da CEAGESP (SP).

O site nao publica arquivo: a pagina tem um formulario (categoria + data) que,
enviado por POST, devolve a tabela de precos em HTML. Nao ha lista de datas
historicas (a pagina so lista as ~2 semanas mais recentes), entao o coletor
percorre o calendario dia a dia, para cada categoria.

Duas etapas, ambas idempotentes:
  1. coleta: guarda a tabela HTML de cada (data, categoria) em <bruto>/AAAA/MM/.
     Consultas sem dado vao para <bruto>/vazios.txt e nao sao repetidas, salvo
     as dos ultimos --revisar-dias (o site pode publicar com atraso).
  2. extracao: le todas as tabelas guardadas e gera o CSV no esquema comum.

Historico disponivel no site: a partir de meados de 2022 (jul/2022 ainda vazio,
out/2022 ja com dados).

Uso:
    python3 ingestao/ceagesp_sp.py                          # 2022-07-01 ate hoje
    python3 ingestao/ceagesp_sp.py --inicio 2026-09-01
    python3 ingestao/ceagesp_sp.py --so-extrair             # refaz o CSV sem acessar o site
"""

from __future__ import annotations

import argparse
import sys
import unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, timedelta
from pathlib import Path

import requests
from bs4 import BeautifulSoup

sys.path.insert(0, str(Path(__file__).resolve().parent))
from coleta_comum import DIR_DADOS, Cliente, confere, escreve_csv, grava_atomico, limpa, linha, numero_br  # noqa: E402

# ------------------------------------------------------------ configuracao

URL = "https://ceagesp.gov.br/cotacoes/"
FONTE = "CEAGESP-SP"
MERCADO = "ENTREPOSTO DA CAPITAL"
INICIO_PADRAO = date(2022, 7, 1)
BRUTO_PADRAO = DIR_DADOS / "cotacoes_sp"
SAIDA_PADRAO = DIR_DADOS / "cotacoes_sp.csv"
CABECALHO_ESPERADO = ["Produto", "Classificação", "Uni/Peso", "Menor", "Comum", "Maior", "Quilo"]


def sem_acento(texto: str) -> str:
    nfkd = unicodedata.normalize("NFKD", texto)
    return "".join(c for c in nfkd if not unicodedata.combining(c))


def arquivo_de(bruto: Path, dia: date, grupo: str) -> Path:
    return bruto / f"{dia:%Y}" / f"{dia:%m}" / f"{dia.isoformat()}_{sem_acento(grupo)}.html"


# ---------------------------------------------------------------- coleta

def categorias(cli: Cliente) -> list[str]:
    """Le as categorias do proprio formulario, para acompanhar mudancas no site."""
    sopa = BeautifulSoup(cli.get(URL).text, "html.parser")
    sel = sopa.find("select", attrs={"name": "cot_grupo"})
    if sel is None:
        raise SystemExit(f"Formulario de cotacao nao encontrado em {URL} (layout mudou?).")
    grupos = [o["value"] for o in sel.find_all("option") if o.get("value")]
    if not grupos:
        raise SystemExit("Formulario sem categorias.")
    return grupos


def consulta(cli: Cliente, dia: date, grupo: str) -> str | None:
    """Tabela HTML da (data, categoria), ou None se o site nao tem cotacao para ela."""
    r = cli.post(URL, data={"cot_grupo": grupo, "cot_data": dia.strftime("%d/%m/%Y")})
    tabela = BeautifulSoup(r.text, "html.parser").find("table", class_="contacao_lista")
    if tabela is None:
        return None
    titulo = limpa(tabela.find("tr").get_text(" ", strip=True))
    # a resposta precisa ser da data e categoria pedidas, nunca outra
    if dia.strftime("%d/%m/%Y") not in titulo or grupo not in titulo:
        raise RuntimeError(f"resposta de outra data/categoria: pedido {dia} {grupo}, veio '{titulo}'")
    return str(tabela)


def le_vazios(caminho: Path) -> set[tuple[str, str]]:
    if not caminho.exists():
        return set()
    return {tuple(l.split("\t", 1)) for l in caminho.read_text(encoding="utf-8").splitlines() if "\t" in l}


def grava_vazios(caminho: Path, vazios: set[tuple[str, str]]) -> None:
    grava_atomico(caminho, "".join(f"{d}\t{g}\n" for d, g in sorted(vazios)).encode("utf-8"))


def coletar(cli: Cliente, bruto: Path, inicio: date, fim: date, revisar_dias: int, workers: int) -> int:
    grupos = categorias(cli)
    print(f"Categorias: {', '.join(grupos)}")
    caminho_vazios = bruto / "vazios.txt"
    vazios = le_vazios(caminho_vazios)
    limite_revisao = (date.today() - timedelta(days=revisar_dias)).isoformat()
    # consultas vazias recentes voltam para a fila
    vazios = {(d, g) for d, g in vazios if d < limite_revisao}

    pendentes = []
    dia = inicio
    while dia <= fim:
        for g in grupos:
            if not arquivo_de(bruto, dia, g).exists() and (dia.isoformat(), g) not in vazios:
                pendentes.append((dia, g))
        dia += timedelta(days=1)
    print(f"Consultas pendentes: {len(pendentes)} ({inicio} a {fim})")

    novos = erros = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futuros = {pool.submit(consulta, cli, d, g): (d, g) for d, g in pendentes}
        for i, fut in enumerate(as_completed(futuros), 1):
            d, g = futuros[fut]
            try:
                tabela = fut.result()
            except (requests.RequestException, RuntimeError) as e:
                erros += 1
                print(f"  ! {d} {g}: {e}", file=sys.stderr)
                continue
            if tabela is None:
                vazios.add((d.isoformat(), g))
            else:
                grava_atomico(arquivo_de(bruto, d, g), tabela.encode("utf-8"))
                novos += 1
            if i % 200 == 0 or i == len(pendentes):
                print(f"  [{i}/{len(pendentes)}] {novos} com dado, {erros} erro(s)")
                grava_vazios(caminho_vazios, vazios)  # progresso salvo para retomar
    grava_vazios(caminho_vazios, vazios)
    print(f"Coleta: {novos} tabela(s) nova(s), {erros} erro(s).")
    return erros


# -------------------------------------------------------------- extracao

def extrai_tabela(caminho: Path, bruto: Path) -> list[dict]:
    dia = date.fromisoformat(caminho.name[:10])
    sopa = BeautifulSoup(caminho.read_text(encoding="utf-8"), "html.parser")
    trs = sopa.find_all("tr")
    titulo = limpa(trs[0].get_text(" ", strip=True))
    grupo = limpa(titulo.split("Categoria:", 1)[1].split("Data:", 1)[0])
    cabecalho = [limpa(c.get_text(" ", strip=True)) for c in trs[1].find_all(["td", "th"])]
    if cabecalho != CABECALHO_ESPERADO:
        raise SystemExit(f"{caminho}: cabecalho inesperado {cabecalho}")

    linhas = []
    for ordem, tr in enumerate(trs[2:]):
        c = [limpa(x.get_text(" ", strip=True)) for x in tr.find_all(["td", "th"])]
        if len(c) != 7:
            raise SystemExit(f"{caminho}: linha com {len(c)} colunas: {c}")
        linhas.append(linha(
            dia, FONTE, MERCADO, grupo, c[0], caminho.relative_to(bruto).as_posix(), ordem,
            classificacao="" if c[1] == "-" else c[1], embalagem=c[2], qtd_kg=numero_br(c[6]),
            preco_minimo=numero_br(c[3]), preco_comum=numero_br(c[4]), preco_maximo=numero_br(c[5]),
        ))
    return linhas


def extrair(bruto: Path, saida: Path) -> int:
    arquivos = sorted(bruto.rglob("*.html"))
    linhas = [l for a in arquivos for l in extrai_tabela(a, bruto)]
    print(f"\nExtracao: {len(arquivos)} tabela(s)")
    escreve_csv(saida, linhas)
    print(f"CSV: {saida.resolve()}")
    return confere(linhas, FONTE)


def main() -> int:
    p = argparse.ArgumentParser(description="Coleta as cotacoes da CEAGESP (SP) e gera CSV.")
    p.add_argument("--inicio", type=date.fromisoformat, default=INICIO_PADRAO, help="AAAA-MM-DD")
    p.add_argument("--fim", type=date.fromisoformat, default=date.today(), help="AAAA-MM-DD (padrao: hoje)")
    p.add_argument("-b", "--bruto", type=Path, default=BRUTO_PADRAO, help="pasta das tabelas brutas")
    p.add_argument("-s", "--saida", type=Path, default=SAIDA_PADRAO, help="CSV de saida")
    p.add_argument("--revisar-dias", type=int, default=7, help="reconsulta vazios desta janela (padrao: 7)")
    p.add_argument("--delay", type=float, default=0.5, help="segundos entre requisicoes (padrao: 0.5)")
    p.add_argument("--workers", type=int, default=4, help="requisicoes simultaneas (padrao: 4)")
    p.add_argument("--so-extrair", action="store_true", help="nao acessa o site, so refaz o CSV")
    args = p.parse_args()

    if args.inicio > args.fim:
        raise SystemExit("--inicio posterior a --fim.")
    erros = 0
    if not args.so_extrair:
        erros = coletar(Cliente(args.delay), args.bruto, args.inicio, args.fim, args.revisar_dias, args.workers)
    falha = extrair(args.bruto, args.saida)
    return 2 if erros else falha


if __name__ == "__main__":
    sys.exit(main())
