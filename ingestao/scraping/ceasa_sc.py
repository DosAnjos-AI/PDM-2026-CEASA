#!/usr/bin/env python3
"""
Coletor das cotacoes diarias da CEASA-SC (unidade Sao Jose).

O site (Joomla) publica um PDF por dia, na hierarquia
    cotacao-de-precos/  ->  pagina por ano  ->  pagina por mes  ->  PDFs
com a lista de cada mes paginada de 20 em 20 (`?limitstart=`; `limit` e
ignorado). O slug do arquivo traz a data, mas com erros de digitacao
(ex.: "877-03-01-2019-1" publicado em jan/2020), entao o bruto e nomeado pelo
id do Joomla e a data usada e a impressa no PDF ("Relatorio de Cotacoes do
dia : DD/MM/AAAA"), como no extrator da CEASA-GO.

Extracao por coordenadas (`pdftotext -bbox`), nao por texto corrido: ha
registros em que a classificacao quebra em duas linhas ("Especial" /
"Escovada") e, no modo texto, os precos desse registro saem em linhas
diferentes. Por coordenada, cada palavra vai para a coluna do cabecalho
sob a qual esta e para o registro cuja linha de precos esta mais proxima.
O layout (10 colunas, mesma ordem e mesmas coordenadas) e o mesmo de 2020
a 2026; ainda assim as fronteiras sao lidas do cabecalho de cada pagina.

Conferencia de alinhamento por registro: a coluna "Comum Kg" do PDF deve
ser preco_comum / qtd_kg. Ela nao vai para o CSV (e derivada).

Duas etapas, ambas idempotentes:
  1. coleta: baixa os PDFs para <bruto>/AAAA/MM/<id>.pdf (ano/mes da pagina).
  2. extracao: le todos os PDFs e gera o CSV no esquema comum. Quando dois
     PDFs tem a mesma data interna, fica o de maior id (o mais recente) e os
     demais sao listados.

Dependencias: requests, beautifulsoup4 e pdftotext (poppler-utils), o mesmo
binario que o extrator da CEASA-GO ja usa.

Uso:
    python3 ingestao/scraping/ceasa_sc.py                    # 2020 ate hoje
    python3 ingestao/scraping/ceasa_sc.py --start-year 2026
    python3 ingestao/scraping/ceasa_sc.py --so-extrair
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path
from urllib.parse import urljoin, urlparse

import requests
from bs4 import BeautifulSoup

sys.path.insert(0, str(Path(__file__).resolve().parent))
from comum import DIR_DADOS, Cliente, grava_atomico, grava_se_conferido, http_404, limpa, linha, numero_br  # noqa: E402

# ------------------------------------------------------------ configuracao

RAIZ = "https://www.ceasa.sc.gov.br/index.php/cotacao-de-precos"
FONTE = "CEASA-SC"
ANO_INICIAL_PADRAO = 2020  # primeira pagina de ano do site
BRUTO_PADRAO = DIR_DADOS / "cotacoes_sc"
SAIDA_PADRAO = DIR_DADOS / "cotacoes_sc.csv"
ITENS_POR_PAGINA = 20

RE_ANO = re.compile(r"/cotacao-de-precos/(\d{4})(?:-\d+)?/?$")
RE_MES = re.compile(r"/(\d{2})-[a-z]+(?:-\d+)?/?$")
RE_ARQUIVO = re.compile(r"/(\d+)-[^/]*/file$")
RE_DATA = re.compile(r"Cotações do dia\s*:\s*(\d{2}/\d{2}/\d{4})")
RE_PRECO = re.compile(r"^\d{1,3}(\.\d{3})*,\d{2}$")
RE_WORD = re.compile(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>')

# colunas na ordem do PDF; a chave e o texto do cabecalho que marca cada uma
COLUNAS_PDF = ["produto", "classificacao", "tipo", "origem", "embalagem",
               "conv_kg", "minimo", "comum", "maximo", "comum_kg"]
# palavras de dados a ate esta distancia vertical (pt) da linha de precos
# pertencem ao registro; registros ficam a ~24 pt um do outro e a
# classificacao quebrada fica a ~5 pt
TOLERANCIA_Y = 10.0
# altura (pt) acima/abaixo de "Produto" onde ficam as 3 linhas do cabecalho
# (de "Preco (R$)" a "Kg"); o primeiro registro fica ~20 pt abaixo
FAIXA_CABECALHO = 10.0
# folga a esquerda do cabecalho "Classificacao": nomes de produto terminam
# antes de x=130 e classificacoes comecam depois de x=160 (medido 2020-2026)
FOLGA_CLASSIFICACAO = 15.0
# tolerancia da conferencia comum_kg == comum / conv_kg (o PDF arredonda)
TOLERANCIA_KG = 0.02


# ---------------------------------------------------------------- coleta

@dataclass(frozen=True)
class Doc:
    url: str
    id: int
    ano: int
    mes: int

    @property
    def destino_rel(self) -> Path:
        return Path(f"{self.ano:04d}") / f"{self.mes:02d}" / f"{self.id}.pdf"


def links(cli: Cliente, url: str) -> list[str]:
    sopa = BeautifulSoup(cli.get(url).text, "html.parser")
    return [urljoin(url, a["href"]) for a in sopa.select("a[href]")]


def anos(cli: Cliente, inicio: int, fim: int) -> list[tuple[int, str]]:
    achados: dict[int, str] = {}
    for u in links(cli, RAIZ):
        m = RE_ANO.search(urlparse(u).path)
        if m and inicio <= int(m.group(1)) <= fim:
            achados.setdefault(int(m.group(1)), u)
    if not achados:
        raise SystemExit(f"Nenhuma pagina de ano entre {inicio} e {fim} em {RAIZ} (layout mudou?).")
    return sorted(achados.items())


def meses(cli: Cliente, url_ano: str) -> list[tuple[int, str]]:
    base = urlparse(url_ano).path.rstrip("/")
    achados: dict[int, str] = {}
    for u in links(cli, url_ano):
        caminho = urlparse(u).path.rstrip("/")
        if caminho.startswith(base + "/") and caminho.count("/") == base.count("/") + 1:
            m = RE_MES.search(caminho)
            if m and 1 <= int(m.group(1)) <= 12:
                achados.setdefault(int(m.group(1)), u.split("?")[0])
    return sorted(achados.items())


def pdfs_do_mes(cli: Cliente, ano: int, mes: int, url_mes: str) -> list[Doc]:
    """Percorre a paginacao do mes ate uma pagina nao trazer arquivo novo."""
    docs: dict[int, Doc] = {}
    inicio = 0
    while True:
        novos = 0
        for u in links(cli, f"{url_mes}?limitstart={inicio}"):
            m = RE_ARQUIVO.search(urlparse(u).path)
            if m and int(m.group(1)) not in docs:
                docs[int(m.group(1))] = Doc(u, int(m.group(1)), ano, mes)
                novos += 1
        if novos < ITENS_POR_PAGINA:
            return list(docs.values())
        inicio += ITENS_POR_PAGINA


def baixar(cli: Cliente, bruto: Path, doc: Doc) -> str:
    destino = bruto / doc.destino_rel
    if destino.exists() and destino.stat().st_size > 0:
        return "existente"
    try:
        conteudo = cli.get(doc.url).content
    except requests.RequestException as e:
        # 404 de link publicado pelo proprio site: nao ha o que coletar, e contar
        # como erro a cada execucao esconderia uma falha nova
        return "indisponivel" if http_404(e) else f"erro: {e.__class__.__name__}"
    if not conteudo.startswith(b"%PDF"):
        return "nao-e-pdf"
    grava_atomico(destino, conteudo)
    return "baixado"


def coletar(cli: Cliente, bruto: Path, inicio: int, fim: int, workers: int) -> int:
    docs: list[Doc] = []
    vistos: set[int] = set()
    for ano, url_ano in anos(cli, inicio, fim):
        lista = meses(cli, url_ano)
        print(f"{ano}: {len(lista)} mes(es)")
        for mes, url_mes in lista:
            # um id listado em dois meses (ex.: bloco de "recentes") fica so no primeiro
            achados = [d for d in pdfs_do_mes(cli, ano, mes, url_mes) if d.id not in vistos]
            vistos.update(d.id for d in achados)
            docs += achados
            print(f"  {ano}-{mes:02d}: {len(achados):3d} PDF(s)")
    pendentes = [d for d in docs if not (bruto / d.destino_rel).exists()]
    print(f"Total: {len(docs)} PDF(s), {len(pendentes)} a baixar")

    contagem: dict[str, int] = {}
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futuros = {pool.submit(baixar, cli, bruto, d): d for d in pendentes}
        for i, fut in enumerate(as_completed(futuros), 1):
            estado = fut.result()
            chave = estado.split(":")[0]
            contagem[chave] = contagem.get(chave, 0) + 1
            if chave == "indisponivel":
                print(f"  aviso: indisponivel na fonte (404): {futuros[fut].url}")
            elif chave != "baixado":
                print(f"  ! {futuros[fut].url}: {estado}", file=sys.stderr)
            if i % 100 == 0 or i == len(pendentes):
                print(f"  [{i}/{len(pendentes)}] " + ", ".join(f"{k}={v}" for k, v in sorted(contagem.items())))
    return contagem.get("erro", 0) + contagem.get("nao-e-pdf", 0)


# -------------------------------------------------------------- extracao

@dataclass
class Palavra:
    x0: float
    y0: float
    x1: float
    y1: float
    texto: str

    @property
    def xc(self) -> float:
        return (self.x0 + self.x1) / 2

    @property
    def yc(self) -> float:
        return (self.y0 + self.y1) / 2


def paginas(pdf: Path) -> list[list[Palavra]]:
    saida = subprocess.run(["pdftotext", "-bbox", str(pdf), "-"], capture_output=True, text=True, check=True).stdout
    return [[Palavra(float(a), float(b), float(c), float(d), html.unescape(t)) for a, b, c, d, t in RE_WORD.findall(p)]
            for p in saida.split("<page ")[1:]]


def fronteiras(pag: list[Palavra]) -> tuple[list[float], float] | None:
    """Limites x entre colunas (lidos do cabecalho) e o y onde comecam os dados; None se nao e pagina de tabela."""
    # o cabecalho e a faixa em torno de "Produto" (1a coluna); fora dela, "Tipo",
    # "Comum" etc. sao dados (ex.: "Alho nobre Tipo 4 e 5")
    produtos = [p for p in pag if p.texto == "Produto"]
    if not produtos:
        return None
    ref = min(produtos, key=lambda p: p.y0)
    faixa = [p for p in pag if ref.y0 - FAIXA_CABECALHO <= p.y0 <= ref.y1 + FAIXA_CABECALHO]

    def unica(texto: str) -> Palavra | None:
        achadas = [p for p in faixa if p.texto == texto]
        return achadas[0] if len(achadas) == 1 else None

    cls, tipo, orig, emb, conv, mini, maxi = (unica(t) for t in (
        "Classificação", "Tipo", "Origem", "Embalagem", "Conv.", "Mínimo", "Máximo"))
    if None in (cls, tipo, orig, emb, conv, mini, maxi):
        return None
    comuns = sorted((p for p in faixa if p.texto == "Comum"), key=lambda p: p.x0)
    com = next((p for p in comuns if mini.x1 < p.xc < maxi.x0), None)
    com_kg = next((p for p in comuns if p.xc > maxi.x1), None)
    if com is None or com_kg is None:
        return None
    centros = [cls.xc, tipo.xc, orig.xc, emb.xc, conv.xc, mini.xc, com.xc, maxi.xc, com_kg.xc]
    limites = [cls.x0 - FOLGA_CLASSIFICACAO] + [(a + b) / 2 for a, b in zip(centros, centros[1:])]
    fim_cabecalho = max(p.y1 for p in faixa)
    return limites, fim_cabecalho


def coluna(x: float, limites: list[float]) -> int:
    for i, lim in enumerate(limites):
        if x < lim:
            return i
    return len(limites)


def cabecalho_do_doc(pags: list[list[Palavra]]) -> tuple[date, str]:
    """Data e unidade impressas no topo da primeira pagina."""
    pag = pags[0]
    texto = " ".join(p.texto for p in pag)
    m = RE_DATA.search(texto)
    if not m:
        raise ValueError("data do relatorio nao encontrada")
    dia = datetime.strptime(m.group(1), "%d/%m/%Y").date()
    # unidade: palavras logo abaixo do rotulo "Unidade :" do topo da pagina
    # (a palavra "Unidade" tambem e embalagem na tabela, dai o filtro de y)
    rotulo = min((p for p in pag if p.texto == "Unidade"), key=lambda p: p.y0)
    unidade = " ".join(p.texto for p in sorted(pag, key=lambda p: p.x0)
                       if abs(p.x0 - rotulo.x0) < 60 and rotulo.y1 < p.y0 < rotulo.y1 + 15)
    return dia, limpa(unidade)


def registros_da_pagina(pag: list[Palavra], problemas: list[str], rotulo: str) -> list[dict[str, str]]:
    f = fronteiras(pag)
    if f is None:
        return []
    limites, fim_cabecalho = f
    dados = [p for p in pag if p.y0 > fim_cabecalho + 1]
    # linha de cada registro: y das palavras de preco nas colunas minimo/comum/maximo
    ancoras: list[float] = []
    for p in sorted(dados, key=lambda p: p.yc):
        if coluna(p.xc, limites) in (6, 7, 8) and RE_PRECO.match(p.texto):
            if not ancoras or p.yc - ancoras[-1] > 3:
                ancoras.append(p.yc)
    if not ancoras:
        return []

    grupos: dict[float, list[Palavra]] = {a: [] for a in ancoras}
    for p in dados:
        perto = min(ancoras, key=lambda a: abs(a - p.yc))
        if abs(perto - p.yc) <= TOLERANCIA_Y:
            grupos[perto].append(p)
        elif ancoras[0] < p.yc < ancoras[-1]:
            # palavra no meio da tabela sem registro: nao pode sumir calada
            problemas.append(f"{rotulo}: palavra solta '{p.texto}' em y={p.yc:.0f}")

    regs = []
    for a in ancoras:
        campos: dict[str, list[str]] = {c: [] for c in COLUNAS_PDF}
        for p in sorted(grupos[a], key=lambda p: (round(p.y0), p.x0)):
            campos[COLUNAS_PDF[coluna(p.xc, limites)]].append(p.texto)
        regs.append({c: " ".join(v) for c, v in campos.items()})
    return regs


def extrai_pdf(pdf: Path, bruto: Path) -> tuple[date, list[dict], list[str], list[str]]:
    problemas: list[str] = []
    kg_divergente: list[str] = []
    rel = pdf.relative_to(bruto).as_posix()
    pags = paginas(pdf)
    if not pags:
        raise ValueError("PDF sem paginas de texto")
    dia, unidade = cabecalho_do_doc(pags)
    linhas = []
    ordem = 0
    for n, pag in enumerate(pags, 1):
        for r in registros_da_pagina(pag, problemas, f"{rel} p{n}"):
            if not r["produto"]:
                problemas.append(f"{rel} p{n}: registro sem produto {r}")
                continue
            comum, conv = numero_br(r["comum"]), numero_br(r["conv_kg"])
            kg = float(r["comum_kg"]) if re.match(r"^\d+(\.\d+)?$", r["comum_kg"]) else None
            if None not in (comum, conv, kg) and conv > 0 and abs(comum / conv - kg) > max(TOLERANCIA_KG, kg * 0.01):
                kg_divergente.append(f"{rel} p{n}: {r['produto']}: comum/conv = {comum / conv:.2f}, PDF diz {kg}")
            linhas.append(linha(
                dia, FONTE, unidade, "", r["produto"], rel, ordem,
                classificacao=r["classificacao"], tipo=r["tipo"], origem=r["origem"],
                embalagem=r["embalagem"], qtd_kg=conv, preco_minimo=numero_br(r["minimo"]),
                preco_comum=comum, preco_maximo=numero_br(r["maximo"]),
            ))
            ordem += 1
    return dia, linhas, problemas, kg_divergente


def extrair(bruto: Path, saida: Path, workers: int, falhas_esperadas: int) -> int:
    if shutil.which("pdftotext") is None:
        raise SystemExit("pdftotext nao encontrado no PATH (pacote poppler-utils).")
    pdfs = sorted(bruto.rglob("*.pdf"), key=lambda p: int(p.stem))
    ids: dict[str, list[str]] = {}
    for pdf in pdfs:
        ids.setdefault(pdf.stem, []).append(pdf.relative_to(bruto).as_posix())
    repetidos = [str(v) for v in ids.values() if len(v) > 1]
    if repetidos:
        raise SystemExit("Mesmo PDF (id) em mais de uma pasta do bruto: " + "; ".join(repetidos))
    por_data: dict[date, list[tuple[int, list[dict]]]] = {}
    falhas: list[str] = []
    problemas: list[str] = []
    kg_divergente: list[str] = []
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futuros = {pool.submit(extrai_pdf, p, bruto): p for p in pdfs}
        for fut in as_completed(futuros):
            pdf = futuros[fut]
            try:
                dia, linhas, probs, kg_div = fut.result()
            except (ValueError, subprocess.CalledProcessError) as e:
                falhas.append(f"{pdf.relative_to(bruto).as_posix()}: {e}")
                continue
            problemas += probs
            kg_divergente += kg_div
            if not linhas:
                falhas.append(f"{pdf.relative_to(bruto).as_posix()}: nenhuma linha de cotacao")
                continue
            por_data.setdefault(dia, []).append((int(pdf.stem), linhas))

    linhas: list[dict] = []
    duplicados: list[str] = []
    for dia, versoes in sorted(por_data.items()):
        versoes.sort(key=lambda v: v[0])
        linhas += versoes[-1][1]  # maior id = publicacao mais recente
        duplicados += [f"{dia}: id {i} descartado, mantido id {versoes[-1][0]}" for i, _ in versoes[:-1]]

    print(f"\nExtracao: {len(pdfs)} PDF(s), {len(falhas)} sem dado, {len(duplicados)} duplicado(s) por data")
    for titulo, lista in (("PDFs sem dado", falhas), ("Datas repetidas", duplicados), ("Avisos", problemas)):
        if lista:
            print(f"{titulo}: {len(lista)}")
            for item in sorted(lista)[:50]:
                print(f"  - {item}")
            if len(lista) > 50:
                print(f"  ... e mais {len(lista) - 50}")
    # o PDF imprime "Comum Kg" errado em parte de 2021-2022 (ex.: caixa de 12 kg
    # a 120,00 com 3,33/kg); por isso so a taxa e informada, como sinal de alinhamento
    total = sum(len(v[-1][1]) for v in por_data.values())
    print(f"Comum Kg do PDF diferente de comum/conv: {len(kg_divergente)} de {total} registro(s)")
    for item in sorted(kg_divergente)[:5]:
        print(f"  - {item}")
    falha = grava_se_conferido(saida, linhas, FONTE)
    if len(falhas) > falhas_esperadas:
        print(f"{len(falhas)} PDF(s) sem dado, acima dos {falhas_esperadas} esperado(s).", file=sys.stderr)
        return 1
    return falha


def main() -> int:
    p = argparse.ArgumentParser(description="Coleta os PDFs de cotacao da CEASA-SC e gera CSV.")
    p.add_argument("--start-year", type=int, default=ANO_INICIAL_PADRAO, help=f"padrao: {ANO_INICIAL_PADRAO}")
    p.add_argument("--end-year", type=int, default=date.today().year, help="padrao: ano corrente")
    p.add_argument("-b", "--bruto", type=Path, default=BRUTO_PADRAO, help="pasta dos PDFs")
    p.add_argument("-s", "--saida", type=Path, default=SAIDA_PADRAO, help="CSV de saida")
    p.add_argument("--delay", type=float, default=0.5, help="segundos entre requisicoes (padrao: 0.5)")
    p.add_argument("--workers", type=int, default=4, help="downloads/extracoes simultaneos (padrao: 4)")
    p.add_argument("--so-extrair", action="store_true", help="nao acessa o site, so refaz o CSV")
    p.add_argument("--falhas-esperadas", type=int, default=0, metavar="N",
                   help="PDFs sem dado tolerados antes de sair com erro (padrao: 0)")
    args = p.parse_args()

    erros = 0
    try:
        if not args.so_extrair:
            erros = coletar(Cliente(args.delay), args.bruto, args.start_year, args.end_year, args.workers)
    except requests.RequestException as e:
        # site fora do ar: o CSV ainda e gerado com o que ja foi baixado
        print(f"! coleta interrompida por falha de rede: {e}", file=sys.stderr)
        erros = 1
    falha = extrair(args.bruto, args.saida, args.workers, args.falhas_esperadas)
    return 2 if erros else falha


if __name__ == "__main__":
    sys.exit(main())
