"""
Logica compartilhada dos coletores de sedes que usam o sistema Scriptcase
(ceasa_mg.py e ceasa_es.py). Nao e executado direto: cada sede chama
`main(cfg)` com a propria configuracao.

Os dois estados usam o mesmo sistema (Scriptcase), com uma tela de filtro
(mercado + data) que leva ao "Boletim Completo" em HTML. O fluxo da tela e
reproduzido sem navegador:

  1. GET no filtro: lista de mercados (campo `mercado`).
  2. POST de recarga com o mercado escolhido: lista de datas com boletim
     (campo `datas`). Essa lista e a fonte da verdade do que existe.
  3. POST direto no boletim com `nmgp_parms`. A data vai como MM/DD/AAAA, ao
     contrario do que a tela mostra; a data impressa no boletim e conferida
     contra a pedida.

Cuidado verificado no MG: com cookie de sessao, o servidor mantem o cabecalho
do primeiro boletim da sessao (data errada) enquanto as linhas acompanham a
data pedida. Por isso o boletim e sempre pedido sem cookie (cliente proprio).

Duas etapas, ambas idempotentes:
  1. coleta: guarda a tabela de cada (mercado, data) em <bruto>/<cod>/AAAA/MM/.
     Boletim que volta "Registros nao encontrados" vai para <bruto>/vazios.txt.
     Tudo dos ultimos --revisar-dias e pedido de novo, inclusive o que ja foi
     baixado: o ES publicou os pescados de 05/10/2026 horas depois do resto.
  2. extracao: le as tabelas guardadas e gera o CSV da sede. Com --carregados,
     so as que ainda nao estao na Bronze e as dos ultimos --meses-recentes.

`cfg` de cada sede: fonte (rotulo no CSV), filtro (URL da tela de filtro),
boletim (URL do boletim completo), bruto e saida (caminhos padrao).
"""

from __future__ import annotations

import argparse
import html
import re
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import date, datetime, timedelta
from pathlib import Path

import requests
from bs4 import BeautifulSoup

sys.path.insert(0, str(Path(__file__).resolve().parent))
from comum import (Cliente, argumentos_incrementais, grava_atomico, grava_se_conferido,  # noqa: E402
                   grava_vazio, limpa, linha, numero_br, seleciona_pendentes)

# ------------------------------------------------------------ configuracao

# colunas do grid do boletim, identificadas pela classe CSS de cada celula
CAMPOS_GRID = ["prdnom", "embdesresu", "pboprcmin", "pboprccomum", "pboprcmax", "mersit"]
RE_DATA_BOLETIM = re.compile(r"Data(?: Pesquisada)?:\s*(\d{2}/\d{2}/\d{4})")
SEM_REGISTRO = "Registros não encontrados"


def arquivo_de(bruto: Path, cod: str, dia: date) -> Path:
    return bruto / cod / f"{dia:%Y}" / f"{dia:%m}" / f"{dia.isoformat()}.html"


# ---------------------------------------------------------------- coleta

def campos_do_form(sopa: BeautifulSoup) -> dict[str, str]:
    form = sopa.find("form", attrs={"name": "F1"})
    if form is None:
        raise SystemExit("Formulario F1 do Scriptcase nao encontrado (layout mudou?).")
    return {i["name"]: i.get("value", "") for i in form.find_all("input") if i.get("name")}


def mercados(cli: Cliente, cfg: dict) -> tuple[dict[str, str], dict[str, str]]:
    """Mercados do filtro ({codigo: nome}) e os campos do formulario para a recarga."""
    sopa = BeautifulSoup(cli.get(cfg["filtro"]).text, "html.parser")
    sel = sopa.find("select", attrs={"name": "mercado"})
    if sel is None:
        raise SystemExit(f"Campo 'mercado' nao encontrado em {cfg['filtro']}.")
    lista = {o["value"]: limpa(o.get_text()) for o in sel.find_all("option") if o.get("value") not in (None, "", "0")}
    if not lista:
        raise SystemExit(f"Nenhum mercado em {cfg['filtro']}.")
    return lista, campos_do_form(sopa)


def datas_do_mercado(cli: Cliente, cfg: dict, campos: dict[str, str], cod: str) -> list[date]:
    """Reproduz o onchange do campo mercado (nm_recarga_form) e le as datas oferecidas."""
    dados = dict(campos, mercado=cod, datas="", nmgp_opcao="recarga", nmgp_parms="", nmgp_ancora="0")
    sopa = BeautifulSoup(cli.post(cfg["filtro"], data=dados).text, "html.parser")
    sel = sopa.find("select", attrs={"name": "datas"})
    if sel is None:
        raise SystemExit(f"Campo 'datas' nao veio na recarga do mercado {cod}.")
    return [datetime.strptime(o["value"].strip(), "%d/%m/%Y").date()
            for o in sel.find_all("option") if o.get("value", "").strip()]


def consulta(cli: Cliente, cfg: dict, cod: str, nome: str, dia: date) -> str | None:
    """HTML reduzido do boletim (titulo + linhas do grid), ou None se nao ha registro."""
    parms = f"mercod*scin{cod}*scoutdata*scin{dia:%m/%d/%Y}*scoutnumero*scin1*scout"
    r = cli.post(cfg["boletim"], data={"nmgp_parms": parms, "script_case_init": "1"})
    if SEM_REGISTRO in r.text:
        return None
    sopa = BeautifulSoup(r.text, "html.parser")
    m = RE_DATA_BOLETIM.search(sopa.get_text(" ", strip=True))
    if not m or m.group(1) != dia.strftime("%d/%m/%Y"):
        raise RuntimeError(f"boletim de outra data: pedido {dia}, veio {m.group(1) if m else 'sem data'}")
    linhas = [tr for tr in sopa.find_all("tr") if tr.find("td", class_="css_prdnom_grid_line", recursive=False)]
    if not linhas:
        raise RuntimeError("boletim sem 'Registros nao encontrados' e sem linhas de grid (layout mudou?)")
    # guarda so o necessario: o boletim inteiro tem ~250 KB de interface
    cab = f'<p data-mercado="{cod}" data-nome="{html.escape(nome)}" data-data="{dia.isoformat()}"></p>\n'
    return cab + "<table>\n" + "\n".join(str(tr) for tr in linhas) + "\n</table>\n"


def le_vazios(caminho: Path) -> set[tuple[str, str]]:
    if not caminho.exists():
        return set()
    return {tuple(l.split("\t", 1)) for l in caminho.read_text(encoding="utf-8").splitlines() if "\t" in l}


def grava_vazios(caminho: Path, vazios: set[tuple[str, str]]) -> None:
    grava_atomico(caminho, "".join(f"{c}\t{d}\n" for c, d in sorted(vazios)).encode("utf-8"))


def coletar(cli: Cliente, cli_boletim: Cliente, cfg: dict, bruto: Path, inicio: date, fim: date,
            so_mercados: set[str] | None, revisar_dias: int, workers: int) -> int:
    lista, campos = mercados(cli, cfg)
    if so_mercados:
        desconhecidos = so_mercados - lista.keys()
        if desconhecidos:
            raise SystemExit(f"Mercado(s) inexistente(s) em {cfg['fonte']}: {sorted(desconhecidos)}. Validos: {lista}")
        lista = {c: n for c, n in lista.items() if c in so_mercados}

    caminho_vazios = bruto / "vazios.txt"
    limite_revisao = (date.today() - timedelta(days=revisar_dias)).isoformat()
    vazios = {(c, d) for c, d in le_vazios(caminho_vazios) if d < limite_revisao}

    pendentes = []
    for cod, nome in lista.items():
        datas = [d for d in datas_do_mercado(cli, cfg, campos, cod) if inicio <= d <= fim]
        faltam = [d for d in datas if d.isoformat() >= limite_revisao
                  or (not arquivo_de(bruto, cod, d).exists() and (cod, d.isoformat()) not in vazios)]
        print(f"  {cfg['fonte']} {cod} {nome}: {len(datas)} data(s) no periodo, {len(faltam)} a baixar")
        pendentes += [(cod, nome, d) for d in faltam]

    novos = erros = 0
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futuros = {pool.submit(consulta, cli_boletim, cfg, c, n, d): (c, d) for c, n, d in pendentes}
        for i, fut in enumerate(as_completed(futuros), 1):
            cod, dia = futuros[fut]
            try:
                tabela = fut.result()
            except (requests.RequestException, RuntimeError) as e:
                erros += 1
                print(f"  ! {cod} {dia}: {e}", file=sys.stderr)
                continue
            if tabela is None:
                vazios.add((cod, dia.isoformat()))
            else:
                grava_atomico(arquivo_de(bruto, cod, dia), tabela.encode("utf-8"))
                novos += 1
            if i % 200 == 0 or i == len(pendentes):
                print(f"  [{i}/{len(pendentes)}] {novos} boletim(ns), {erros} erro(s)")
                grava_vazios(caminho_vazios, vazios)  # progresso salvo para retomar
    grava_vazios(caminho_vazios, vazios)
    print(f"Coleta {cfg['fonte']}: {novos} boletim(ns) gravado(s), {erros} erro(s).")
    return erros


# -------------------------------------------------------------- extracao

def extrai_boletim(caminho: Path, bruto: Path, fonte: str) -> list[dict]:
    sopa = BeautifulSoup(caminho.read_text(encoding="utf-8"), "html.parser")
    cab = sopa.find("p")
    dia = date.fromisoformat(cab["data-data"])
    nome = cab["data-nome"]
    linhas = []
    for ordem, tr in enumerate(sopa.find_all("tr")):
        c = {}
        for campo in CAMPOS_GRID:
            td = tr.find("td", class_=f"css_{campo}_grid_line", recursive=False)
            if td is None:
                raise SystemExit(f"{caminho}: linha sem a coluna {campo}")
            c[campo] = limpa(td.get_text(" ", strip=True))
        linhas.append(linha(
            dia, fonte, nome, "", c["prdnom"], caminho.relative_to(bruto).as_posix(), ordem,
            embalagem=c["embdesresu"], preco_minimo=numero_br(c["pboprcmin"]),
            preco_comum=numero_br(c["pboprccomum"]), preco_maximo=numero_br(c["pboprcmax"]),
            situacao=c["mersit"],
        ))
    return linhas


def extrair(cfg: dict, bruto: Path, saida: Path,
            carregados: Path | None = None, meses_recentes: int = 2) -> int:
    fonte = cfg["fonte"]
    arquivos = seleciona_pendentes(sorted(bruto.rglob("*.html")), bruto, carregados, meses_recentes)
    if not arquivos:
        return grava_vazio(saida, fonte)
    linhas = [l for a in arquivos for l in extrai_boletim(a, bruto, fonte)]
    print(f"\nExtracao {fonte}: {len(arquivos)} boletim(ns)")
    return grava_se_conferido(saida, linhas, fonte)


def main(cfg: dict) -> int:
    p = argparse.ArgumentParser(description=f"Coleta os boletins diarios da {cfg['fonte']} e gera CSV.")
    p.add_argument("--mercados", type=lambda s: set(s.split(",")), default=None,
                   help="codigos separados por virgula (padrao: todos)")
    p.add_argument("--inicio", type=date.fromisoformat, default=date(2000, 1, 1), help="AAAA-MM-DD")
    p.add_argument("--fim", type=date.fromisoformat, default=date.today(), help="AAAA-MM-DD (padrao: hoje)")
    p.add_argument("-b", "--bruto", type=Path, default=cfg["bruto"], help="pasta dos boletins brutos")
    p.add_argument("-s", "--saida", type=Path, default=cfg["saida"], help="CSV de saida")
    p.add_argument("--revisar-dias", type=int, default=7, help="pede de novo tudo desta janela (padrao: 7)")
    p.add_argument("--delay", type=float, default=0.5, help="segundos entre requisicoes (padrao: 0.5)")
    p.add_argument("--workers", type=int, default=4, help="requisicoes simultaneas (padrao: 4)")
    p.add_argument("--so-extrair", action="store_true", help="nao acessa o site, so refaz o CSV")
    argumentos_incrementais(p)
    args = p.parse_args()

    erros = 0
    try:
        if not args.so_extrair:
            # boletim sempre sem cookie: ver o cuidado no topo do modulo
            erros = coletar(Cliente(args.delay), Cliente(args.delay, cookies=False), cfg, args.bruto,
                            args.inicio, args.fim, args.mercados, args.revisar_dias, args.workers)
    except requests.RequestException as e:
        # site fora do ar: o CSV ainda e gerado com o que ja foi baixado
        print(f"! coleta interrompida por falha de rede: {e}", file=sys.stderr)
        erros = 1
    falha = extrair(cfg, args.bruto, args.saida, args.carregados, args.meses_recentes)
    return 2 if erros else falha
