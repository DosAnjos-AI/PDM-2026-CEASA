"""
Extrai as tabelas de cotacao dos PDFs da CEASA-GO para um unico CSV.

O site trocou de sistema algumas vezes; os PDFs vem em cinco formatos, todos
tratados aqui:

  1. ANTIGO SEM CODIGO (2019 ate meados de 2022) -- a linha comeca no nome:
        ACELGA EM UNIDADE          UN     2     1     2,00   2,00   2,00   1,000

  2. ANTIGO COM CODIGO (meados de 2022 ate 2026-08-06):
        10 ACELGA                  CX    15     1    80,00  80,00  70,00   5,333
                                   <continuacao>  2  40,00  40,00  30,00   1,538
     Classes extras vem em linhas sem codigo/nome, herdando o produto anterior
     -- inclusive atravessando a quebra de pagina.

  3. ANTIGO COM CODIGO EM COLUNA PROPRIA (3 dias avulsos): 9 campos por linha.

  4. NOVO, "Grupo BIOS" (a partir de 2026-08-07):
        10        ACELGA     CX   15,00   1    60,00  70,00  50,00   4,00
        414       ALFACE           0,00   1     8,00   9,00   7,00   0,00
                  AMERICANA
     Nome quebra em varias linhas e a coluna EMBALAGEM pode vir vazia.

  5. CUPOM (PDFs sem camada de texto, lidos por OCR):
        10 ACELGA (TIPO 1)
             60,00       60,00       60,00
     Tres colunas na ordem MINIMO COMUM MAXIMO -- ordem diferente dos demais
     layouts. Nao traz embalagem, quantidade nem preco por kg. Ha tambem a
     variante com produto e precos na mesma linha.

Nos layouts 1-4 as colunas sao separadas por 2+ espacos no texto com layout
preservado, o que da uma divisao exata. Nao se usa vocabulario de embalagem
para dividir, porque ha produtos cujo nome contem "CX" e "KG" (ex.:
"CAQUI CX C/9 KG").

Dependencias externas, que precisam estar no PATH: pdftotext e pdftoppm do
poppler-utils; tesseract com o pacote de portugues, so quando se usa --ocr.
Desenvolvido e testado em Linux; roda em Windows se esses binarios estiverem
no PATH.

Uso:
    python3 ceasa_extrair.py                       # le ./cotacoes -> ./cotacoes.csv
    python3 ceasa_extrair.py --ocr --resumo        # inclui os PDFs de imagem
    python3 ceasa_extrair.py cotacoes/2026/09/2026-09-04.pdf
"""

from __future__ import annotations

import argparse
import collections
import csv
import difflib
import re
import shutil
import subprocess
import tempfile
import sys
from concurrent.futures import ThreadPoolExecutor
from dataclasses import astuple, dataclass, fields
from pathlib import Path

# ---------------------------------------------------------------- padroes

RE_PRECOS_FIM = re.compile(r"(?:\d[\d.]*,\d+\s+){3}\d[\d.]*,\d+\s*$")
RE_NUM = re.compile(r"^\d[\d.]*,\d+$|^\d+$")
RE_CAT_ANTIGO = re.compile(r"^\s*(\d{2})-(.+?)\s*$")
RE_CAT_NOVO = re.compile(r"^\s*\d+\s+(\d{2})-(.+?)\s*$")
RE_DATA = re.compile(r"(\d{2})/(\d{2})/(\d{4})")
# layout "cupom" (PDFs so de desenho, lidos por OCR): o produto vem numa linha
# e os tres precos na linha seguinte, na ordem MINIMO COMUM MAXIMO -- ordem
# diferente dos outros layouts, que trazem +COMUM MAXIMO MINIMO.
RE_CUPOM_PRODUTO = re.compile(r"^\s*(\d{1,5})\s+(.+?)\s*\(\s*TIPO\s*(\d{1,3})\s*\)\s*$", re.I)
RE_CUPOM_PRECOS = re.compile(
    r"^\s*(\d[\d.]*,\d{2})\s+(\d[\d.]*,\d{2})\s+(\d[\d.]*,\d{2})\s*$")
RE_CUPOM_CAT = re.compile(r"^\s*(\d{2})-(.+?)\s*$")
# variante do cupom em que produto e precos ficam na mesma linha:
#   "10 ACELGA (TIPO 1) 50,00 50,00 70,00"
RE_CUPOM_LINHA = re.compile(
    r"^\s*(\d{1,5})\s+(.+?)\s*\(\s*TIPO\s*(\d{1,3})\s*\)\s+"
    r"(\d[\d.]*,\d{2})\s+(\d[\d.]*,\d{2})\s+(\d[\d.]*,\d{2})\s*$", re.I)
RE_TOKEN_PRECO = re.compile(r"^\d[\d.]*,\d{2}$")
RE_DATA_ARQ = re.compile(r"(\d{4})-(\d{2})-(\d{2})")
RE_NOME_QUEBRA = re.compile(r"^\s{2,}[A-ZÀ-Ú][A-ZÀ-Ú0-9 ,.\-/]*$")

# Linhas de cabecalho/rodape que nunca sao dados. Os marcadores precisam ser
# especificos: ha produtos chamados "EMBALAGEM DE PAPEL" e "EMBALAGEM DE
# PLASTICO", entao um marcador solto "EMBALAGEM" descartaria produtos reais.
# Por seguranca, o filtro so roda depois do teste de linha de dados.
RUIDO = (
    "CENTRAIS DE ABASTECIMENTO", "Cotacao de Preco", "COTAÇÃO DE PREÇOS",
    "COTAÇÃO DO DIA", "Nome Produto", "CÓDIGO", "PREÇO (R$)", "+COMUM",
    "+Comum", "Pagina.:", "Emitido", "Hora....", "TODOS PRODUTOS", "Periodo :",
    "Modelo ", "Classificacao", "Linksim", "Legenda", "DATA DA COTA",
    "PERÍODO", "EMISSÃO", "R$/kg", "Valores podem variar", "Fonte Div",
    "Grupo BIOS", "www.", "Preco Em R$", "Padrao",
)

# o numero do grupo mudou entre os layouts (RAIZES e 03 no antigo e 01 no
# novo), entao a sigla e a unica chave estavel entre os dois formatos.
GRUPOS = (
    ("HFFH", ("HORTALICAS, FOLHAS", "HFFH")),
    ("HF", ("HORTALICAS FRUTOS", "-HF")),
    ("RTB", ("RAIZES", "RTB")),
    ("FN", ("FRUTAS NACIONAIS", "-FN")),
    ("FI", ("FRUTAS IMPORTADAS", "-FI")),
    ("AO", ("AVES E OVOS", "-AO")),
    ("PD", ("DIVERSOS", "-PD")),
    ("CE", ("CEREAIS", "-CE")),
)


@dataclass
class Linha:
    data: str
    ano: int
    mes: int
    dia: int
    grupo: str
    categoria: str
    codigo: str
    produto: str
    embalagem: str
    qtd_kg: float | None
    classe: str
    preco_comum: float | None
    preco_maximo: float | None
    preco_minimo: float | None
    preco_kg: float | None
    layout: str
    arquivo: str


def numero(txt: str) -> float | None:
    """Converte '1.234,56' / '15,00' / '9' em float."""
    txt = (txt or "").strip()
    if not txt:
        return None
    try:
        return float(txt.replace(".", "").replace(",", "."))
    except ValueError:
        return None


def sigla_grupo(categoria: str) -> str:
    alvo = categoria.upper()
    for sigla, marcas in GRUPOS:
        if any(m.upper() in alvo for m in marcas):
            return sigla
    return ""


def e_ruido(linha: str) -> bool:
    return any(m in linha for m in RUIDO)


# ---------------------------------------------------------------- pdftotext


def texto_do_pdf(caminho: Path, timeout: int = 120) -> str:
    r = subprocess.run(
        ["pdftotext", "-layout", "-enc", "UTF-8", str(caminho), "-"],
        capture_output=True, text=True, timeout=timeout,
    )
    if r.returncode != 0:
        raise RuntimeError(f"pdftotext falhou: {r.stderr.strip()[:200]}")
    return r.stdout


def detectar_layout(texto: str) -> str:
    cabeca = texto[:3000]
    if "Nome Produto" in cabeca:
        return "antigo"
    if "CÓDIGO" in cabeca and "EMBALAGEM" in cabeca:
        return "novo"
    if "(TIPO" in texto.upper() and "COMUM" in cabeca.upper():
        return "cupom"
    if not texto.strip():
        return "sem-texto"
    # boletim semanal comparativo: uma coluna por data, com % de variacao e
    # coluna "SITUACAO". E outro relatorio, nao a cotacao diaria por produto.
    if "PRINCIPAIS PRODUTOS COMERCIALIZADOS" in cabeca.upper():
        return "resumo-semanal"
    return "desconhecido"


def ocr_do_pdf(caminho: Path, dpi: int = 300, idioma: str = "por") -> str:
    """Rasteriza o PDF e passa cada pagina no tesseract.

    Usado nos PDFs que nao tem camada de texto (sao desenho vetorial puro:
    pdffonts nao lista nenhuma fonte e nao ha operadores Tj/TJ).
    """
    with tempfile.TemporaryDirectory() as tmp:
        prefixo = Path(tmp) / "pg"
        r = subprocess.run(
            ["pdftoppm", "-r", str(dpi), "-gray", "-png", str(caminho), str(prefixo)],
            capture_output=True, text=True, timeout=600,
        )
        if r.returncode != 0:
            raise RuntimeError(f"pdftoppm falhou: {r.stderr.strip()[:200]}")

        partes = []
        for png in sorted(Path(tmp).glob("pg*.png")):
            # --psm 6 = bloco unico de texto, que e o que preserva as linhas
            r = subprocess.run(
                ["tesseract", str(png), "stdout", "-l", idioma, "--psm", "6"],
                capture_output=True, text=True, timeout=600,
            )
            if r.returncode != 0:
                raise RuntimeError(f"tesseract falhou: {r.stderr.strip()[:200]}")
            partes.append(r.stdout)
    return "\n".join(partes)


def idioma_ocr() -> str:
    """Prefere o pacote em portugues; cai para ingles se nao estiver instalado."""
    r = subprocess.run(["tesseract", "--list-langs"], capture_output=True, text=True)
    return "por" if "por" in r.stdout.split() else "eng"


def data_do_documento(texto: str, layout: str, caminho: Path) -> tuple[str, bool]:
    """Retorna (AAAA-MM-DD, bate_com_o_nome_do_arquivo)."""
    achada = None
    for linha in texto.split("\n")[:40]:
        # "Periodo : DD/MM/AAAA" no antigo, "COTAÇÃO DO DIA DD/MM/AAAA" na
        # variante de julho/2026, "DD/MM/AAAA ate DD/MM/AAAA" no novo.
        if layout == "antigo" and ("Periodo" in linha or "COTAÇÃO DO DIA" in linha):
            m = RE_DATA.search(linha)
        elif layout == "novo" and ("até" in linha or "ate" in linha):
            m = RE_DATA.search(linha)
        elif layout == "cupom" and "Data" in linha:
            m = RE_DATA.search(linha)
        else:
            continue
        if m:
            achada = f"{m.group(3)}-{m.group(2)}-{m.group(1)}"
            break

    m_arq = RE_DATA_ARQ.search(caminho.stem)
    do_arquivo = m_arq.group(0) if m_arq else ""
    if achada is None:
        return do_arquivo, True
    return achada, (not do_arquivo or achada == do_arquivo)


# ---------------------------------------------------------------- parsers


def _monta(campos_num: list[str]) -> tuple:
    """(qtd, classe, comum, maximo, minimo, preco_kg) a partir dos 6 numeros finais."""
    qtd, classe, comum, maximo, minimo, pkg = campos_num
    return (numero(qtd), classe.strip(), numero(comum), numero(maximo),
            numero(minimo), numero(pkg))


def extrair_antigo(texto: str) -> list[dict]:
    linhas: list[dict] = []
    categoria = ""
    atual: dict | None = None

    for bruta in texto.split("\n"):
        if not bruta.strip():
            continue

        # o teste de dados vem antes do de ruido: uma linha que termina em 4
        # precos e sempre dado, mesmo que o nome do produto lembre um cabecalho
        if not RE_PRECOS_FIM.search(bruta):
            if e_ruido(bruta):
                continue  # cabecalho de pagina nao interrompe o produto atual
            m = RE_CAT_ANTIGO.match(bruta)
            if m:
                # a classe 2 de um produto pode cair na pagina seguinte, depois
                # do cabecalho de categoria repetido; so uma categoria de fato
                # diferente encerra a heranca.
                nova = f"{m.group(1)}-{m.group(2)}"
                if nova != categoria:
                    categoria, atual = nova, None
            continue

        campos = re.split(r"\s{2,}", bruta.strip())

        # linha completa. Em quase todos os arquivos o codigo e o nome caem no
        # mesmo campo ("10 ACELGA"); em alguns dias o codigo fica numa coluna
        # propria e a linha tem 9 campos.
        if len(campos) in (8, 9):
            if len(campos) == 9:
                codigo, produto, emb, qtd, classe, comum, mx, mn, pkg = campos
                codigo, produto = codigo.strip(), produto.strip()
                if not codigo.isdigit():
                    continue
            else:
                cod_nome, emb, qtd, classe, comum, mx, mn, pkg = campos
                # ate meados de 2022 nao havia coluna de codigo: a linha comeca
                # direto no nome do produto ("ACELGA EM UNIDADE   CX  2 ...").
                partes = cod_nome.split(None, 1)
                if len(partes) > 1 and partes[0].isdigit():
                    codigo, produto = partes[0], partes[1].strip()
                else:
                    codigo, produto = "", cod_nome.strip()
            atual = {"categoria": categoria, "codigo": codigo, "produto": produto,
                     "embalagem": emb.strip(), "qtd": qtd}
            linhas.append({**atual, "classe": classe.strip(), "comum": comum,
                           "maximo": mx, "minimo": mn, "pkg": pkg})

        # continuacao: apenas classe + 4 precos, herda o produto anterior
        elif len(campos) == 5 and atual and campos[0].strip().isdigit():
            classe, comum, mx, mn, pkg = campos
            linhas.append({**atual, "classe": classe.strip(), "comum": comum,
                           "maximo": mx, "minimo": mn, "pkg": pkg})

    return linhas


def extrair_novo(texto: str) -> list[dict]:
    linhas: list[dict] = []
    categoria = ""
    ultimo: dict | None = None  # ultima linha emitida, para colar nome quebrado

    for bruta in texto.split("\n"):
        if not bruta.strip():
            continue

        if not RE_PRECOS_FIM.search(bruta):  # ver comentario em extrair_antigo
            if e_ruido(bruta):
                ultimo = None  # cabecalho de pagina: nao ha nome pendente
                continue
            m = RE_CAT_NOVO.match(bruta)
            if m:
                categoria = f"{m.group(1)}-{m.group(2)}"
                ultimo = None
                continue
        else:
            campos = re.split(r"\s{2,}", bruta.strip())
            if len(campos) == 9:
                codigo, produto, emb, *resto = campos
            elif len(campos) == 8:  # coluna EMBALAGEM vazia
                codigo, produto, *resto = campos
                emb = ""
            else:
                continue
            if not codigo.strip().isdigit():
                continue
            qtd, classe, comum, mx, mn, pkg = resto
            ultimo = {"categoria": categoria, "codigo": codigo.strip(),
                      "produto": produto.strip(), "embalagem": emb.strip(),
                      "qtd": qtd, "classe": classe.strip(), "comum": comum,
                      "maximo": mx, "minimo": mn, "pkg": pkg}
            linhas.append(ultimo)
            continue

        # continuacao do nome do produto na linha seguinte
        if ultimo is not None and RE_NOME_QUEBRA.match(bruta):
            ultimo["produto"] = f"{ultimo['produto']} {bruta.strip()}".strip()

    return linhas


def separa_nome_emb(toks: list[str], conhecidos: set[str],
                    embalagens: set[str]) -> tuple[str, str]:
    """Decide onde acaba o nome do produto e comeca a embalagem.

    Nao da para usar so o vocabulario de embalagens: ha produtos cujo nome
    termina em "CX" ou "KG" (ex.: "CAQUI CX C/9 KG"). Entao tenta primeiro
    casar o maior prefixo que seja um nome ja visto nos PDFs com texto.
    """
    if not toks:
        return "", ""
    for k in range(len(toks), 0, -1):
        if len(toks) - k <= 1 and " ".join(toks[:k]) in conhecidos:
            return " ".join(toks[:k]), (toks[k] if k < len(toks) else "")
    if len(toks) > 1 and toks[-1] in embalagens:
        return " ".join(toks[:-1]), toks[-1]
    return " ".join(toks), ""


def extrair_novo_ocr(texto: str, conhecidos: set[str],
                     embalagens: set[str]) -> list[dict]:
    """Layout novo lido por OCR.

    O OCR nao preserva as colunas (tudo vira espaco simples), entao os campos
    sao recuperados da direita para a esquerda: 4 precos, classe, quantidade.
    O que sobra e codigo + nome + embalagem opcional.
    """
    linhas: list[dict] = []
    categoria = ""
    ultimo: dict | None = None

    for bruta in texto.split("\n"):
        s = bruta.strip()
        if not s:
            continue
        if e_ruido(s):
            ultimo = None
            continue

        toks = s.split()
        fim_numerico = (
            len(toks) >= 7
            and all(RE_TOKEN_PRECO.match(t) for t in toks[-4:])
            and toks[-5].isdigit()
            and RE_TOKEN_PRECO.match(toks[-6])
        )

        if not fim_numerico:
            m = RE_CAT_NOVO.match(s)
            if m:
                categoria, ultimo = f"{m.group(1)}-{m.group(2)}", None
            elif ultimo is not None and not any(c.isdigit() for c in s):
                ultimo["produto"] = f"{ultimo['produto']} {s}".strip()
            continue

        comum, mx, mn, pkg = toks[-4:]
        classe, qtd = toks[-5], toks[-6]
        meio = toks[:-6]
        if not meio:
            continue
        codigo, resto = meio[0], meio[1:]
        nome, emb = separa_nome_emb(resto, conhecidos, embalagens)
        ultimo = {"categoria": categoria, "codigo": codigo.strip("!|.,"),
                  "produto": nome, "embalagem": emb, "qtd": qtd,
                  "classe": classe, "comum": comum, "maximo": mx,
                  "minimo": mn, "pkg": pkg}
        linhas.append(ultimo)

    return linhas


def extrair_cupom(texto: str) -> list[dict]:
    """Layout de cupom (via OCR).

        01-HORTALICAS, FOLHAS, FLOR, HASTES-
        HFFH
        10 ACELGA (TIPO 1)
             60,00       60,00       60,00        <- MINIMO COMUM MAXIMO

    Nao traz embalagem, quantidade nem preco por kg: esses campos ficam vazios.
    """
    linhas: list[dict] = []
    categoria = ""
    pendente_cat = ""   # cabecalho de categoria quebrado em duas linhas
    produto: dict | None = None

    for bruta in texto.split("\n"):
        linha = bruta.strip()
        if not linha or set(linha) <= set("=- "):
            continue

        if pendente_cat:
            categoria = f"{pendente_cat}{linha}"
            pendente_cat = ""
            produto = None
            continue

        m = RE_CUPOM_CAT.match(linha)
        if m and not RE_CUPOM_PRECOS.match(linha) and "(TIPO" not in linha.upper():
            texto_cat = f"{m.group(1)}-{m.group(2)}"
            if texto_cat.endswith("-"):      # "...HASTES-" continua na linha seguinte
                pendente_cat = texto_cat
            else:
                categoria, produto = texto_cat, None
            continue

        m = RE_CUPOM_LINHA.match(linha)
        if m:
            cod, nome, classe, minimo, comum, maximo = m.groups()
            linhas.append({"categoria": categoria, "codigo": cod,
                           "produto": nome.strip(), "classe": classe,
                           "embalagem": "", "qtd": "", "comum": comum,
                           "maximo": maximo, "minimo": minimo, "pkg": ""})
            produto = None
            continue

        m = RE_CUPOM_PRODUTO.match(linha)
        if m:
            produto = {"categoria": categoria, "codigo": m.group(1),
                       "produto": m.group(2).strip(), "classe": m.group(3)}
            continue

        m = RE_CUPOM_PRECOS.match(linha)
        if m and produto:
            minimo, comum, maximo = m.groups()   # ordem das colunas do cupom
            linhas.append({**produto, "embalagem": "", "qtd": "",
                           "comum": comum, "maximo": maximo, "minimo": minimo,
                           "pkg": ""})
            produto = None

    return linhas


# ---------------------------------------------------------------- por arquivo


def monta_linhas(cruas: list[dict], data: str, layout: str, rel: str) -> list[Linha]:
    ano, mes, dia = (int(x) for x in data.split("-")) if data else (0, 0, 0)
    return [
        Linha(
            data=data, ano=ano, mes=mes, dia=dia,
            grupo=sigla_grupo(c["categoria"]), categoria=c["categoria"],
            codigo=c["codigo"], produto=re.sub(r"\s+", " ", c["produto"]).strip(),
            embalagem=c["embalagem"], qtd_kg=numero(c["qtd"]), classe=c["classe"],
            preco_comum=numero(c["comum"]), preco_maximo=numero(c["maximo"]),
            preco_minimo=numero(c["minimo"]), preco_kg=numero(c["pkg"]),
            layout=layout, arquivo=rel,
        )
        for c in cruas
    ]


@dataclass
class Resultado:
    arquivo: Path
    layout: str
    data: str
    linhas: list[Linha]
    erro: str = ""
    data_divergente: bool = False
    texto_ocr: str = ""   # guardado quando o parse depende do dicionario


def processar(caminho: Path, raiz: Path, ocr: bool = False, dpi: int = 300,
              idioma: str = "por") -> Resultado:
    rel = str(caminho.relative_to(raiz)) if raiz in caminho.parents else caminho.name
    try:
        texto = texto_do_pdf(caminho)
    except Exception as e:  # noqa: BLE001 - qualquer falha vira relatorio
        return Resultado(caminho, "erro", "", [], f"{e.__class__.__name__}: {e}")

    layout = detectar_layout(texto)
    if layout == "sem-texto":
        if not ocr:
            return Resultado(caminho, layout, "", [],
                             "PDF sem camada de texto (rode com --ocr)")
        try:
            texto = ocr_do_pdf(caminho, dpi, idioma)
        except Exception as e:  # noqa: BLE001
            return Resultado(caminho, "ocr", "", [], f"OCR falhou: {e}")
        layout = detectar_layout(texto)
        if layout in ("sem-texto", "desconhecido"):
            return Resultado(caminho, "ocr", "", [], "OCR nao reconheceu o layout")
        layout = f"{layout}-ocr"
    if layout == "resumo-semanal":
        return Resultado(caminho, layout, "", [],
                         "boletim semanal comparativo, nao e a cotacao diaria")
    if layout == "desconhecido":
        return Resultado(caminho, layout, "", [], "layout nao reconhecido")

    base = layout.removesuffix("-ocr")
    data, confere = data_do_documento(texto, base, caminho)
    if layout == "novo-ocr":
        # depende do dicionario de produtos montado a partir dos PDFs com
        # texto, entao e resolvido numa segunda passada em main()
        r = Resultado(caminho, layout, data, [], "", not confere)
        r.texto_ocr = texto
        return r
    cruas = {"antigo": extrair_antigo, "novo": extrair_novo,
             "cupom": extrair_cupom}[base](texto)

    saida = monta_linhas(cruas, data, layout, rel)
    erro = "" if saida else "nenhuma linha extraida"
    return Resultado(caminho, layout, data, saida, erro, not confere)


# ---------------------------------------------------------------- principal


def main() -> int:
    p = argparse.ArgumentParser(description="Extrai as cotacoes dos PDFs da CEASA-GO para CSV.")
    p.add_argument("pdfs", nargs="*", type=Path, help="PDFs especificos (padrao: varre --entrada)")
    p.add_argument("-e", "--entrada", type=Path, default=Path("cotacoes"), help="pasta com os PDFs")
    p.add_argument("-s", "--saida", type=Path, default=Path("cotacoes.csv"), help="CSV de saida")
    p.add_argument("--falhas", type=Path, default=None, help="CSV com os arquivos problematicos")
    p.add_argument("--workers", type=int, default=8, help="processos paralelos de pdftotext")
    p.add_argument("--resumo", action="store_true", help="mostra estatisticas por grupo e produto")
    p.add_argument("--ocr", action="store_true",
                   help="usa OCR nos PDFs sem camada de texto (exige tesseract)")
    p.add_argument("--dpi", type=int, default=300, help="resolucao do OCR (padrao: 300)")
    args = p.parse_args()

    if not shutil.which("pdftotext"):
        print("pdftotext nao encontrado. Instale o poppler-utils:\n"
              "  sudo apt install poppler-utils", file=sys.stderr)
        return 1

    arquivos = sorted(args.pdfs) if args.pdfs else sorted(args.entrada.rglob("*.pdf"))
    if not arquivos:
        print(f"Nenhum PDF encontrado em {args.entrada}", file=sys.stderr)
        return 1
    print(f"Lendo {len(arquivos)} PDF(s)...")

    idioma = "por"
    if args.ocr:
        if not shutil.which("tesseract"):
            print("tesseract nao encontrado. Instale:\n"
                  "  sudo apt install tesseract-ocr tesseract-ocr-por", file=sys.stderr)
            return 1
        idioma = idioma_ocr()
        if idioma != "por":
            print("Aviso: pacote tesseract-ocr-por ausente, usando ingles.", file=sys.stderr)

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        resultados = list(pool.map(
            lambda f: processar(f, args.entrada, args.ocr, args.dpi, idioma), arquivos))

    # O OCR erra nomes de produto de vez em quando. Os PDFs com texto dao um
    # dicionario confiavel de codigo -> nome, entao os nomes lidos por OCR sao
    # conferidos contra ele e corrigidos quando o codigo e conhecido.
    canonico: dict[str, collections.Counter] = collections.defaultdict(collections.Counter)
    for r in resultados:
        if not r.layout.endswith("-ocr"):
            for linha in r.linhas:
                if linha.codigo:  # ate meados de 2022 nao havia codigo
                    canonico[linha.codigo][linha.produto] += 1
    nomes = {cod: c.most_common(1)[0][0] for cod, c in canonico.items()}
    codigos = {nome: cod for cod, nome in nomes.items()}

    # segunda passada: o layout novo lido por OCR perde as colunas, entao
    # precisa do dicionario de nomes/embalagens montado acima.
    conhecidos = {linha.produto for r in resultados if not r.layout.endswith("-ocr")
                  for linha in r.linhas}
    embalagens = {linha.embalagem for r in resultados if not r.layout.endswith("-ocr")
                  for linha in r.linhas if linha.embalagem}
    for r in resultados:
        if r.layout == "novo-ocr" and r.texto_ocr and not r.linhas:
            rel = str(r.arquivo.relative_to(args.entrada)) \
                if args.entrada in r.arquivo.parents else r.arquivo.name
            r.linhas = monta_linhas(
                extrair_novo_ocr(r.texto_ocr, conhecidos, embalagens),
                r.data, r.layout, rel)
            r.erro = "" if r.linhas else "nenhuma linha extraida"

    corrigidos = desconhecidos = recuperados = 0
    divergentes_nome: list[tuple[str, str, str]] = []
    for r in resultados:
        if not r.layout.endswith("-ocr"):
            continue
        for linha in r.linhas:
            # O nome do produto e bem mais confiavel que o codigo no OCR: e
            # uma palavra longa com contexto, enquanto o codigo sao 1-3
            # digitos soltos ("11" virou "1", "77" virou "7"). Por isso o
            # nome manda, e o codigo e derivado dele quando possivel.
            if linha.produto in codigos:
                if linha.codigo != codigos[linha.produto]:
                    linha.codigo = codigos[linha.produto]
                    recuperados += 1
                continue
            certo = nomes.get(linha.codigo)
            if certo is None:
                desconhecidos += 1
            elif certo != linha.produto:
                # nome desconhecido + codigo conhecido: provavelmente erro de
                # leitura no nome ("ALFACELISA"). So corrige se for parecido;
                # diferenca grande significa que o codigo tambem esta errado.
                razao = difflib.SequenceMatcher(None, certo, linha.produto).ratio()
                if razao >= 0.6:
                    linha.produto = certo
                    corrigidos += 1
                else:
                    divergentes_nome.append((linha.codigo, linha.produto, certo))
    if corrigidos or desconhecidos or recuperados or divergentes_nome:
        print(f"\nOCR: {corrigidos} nome(s) corrigido(s) pelo codigo; "
              f"{recuperados} codigo(s) recuperado(s) pelo nome; "
              f"{desconhecidos} linha(s) sem correspondencia.")
        for cod, lido, conhecido in sorted(set(divergentes_nome)):
            print(f"  codigo {cod}: OCR leu {lido!r}, nos PDFs com texto e {conhecido!r} (mantido o do OCR)")

    args.saida.parent.mkdir(parents=True, exist_ok=True)
    colunas = [c.name for c in fields(Linha)]
    total = 0
    with args.saida.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(colunas)
        for r in sorted(resultados, key=lambda r: (r.data, str(r.arquivo))):
            for linha in r.linhas:
                w.writerow(astuple(linha))
                total += 1

    ok = [r for r in resultados if r.linhas]
    falhas = [r for r in resultados if not r.linhas]
    divergentes = [r for r in ok if r.data_divergente]

    por_layout: dict[str, int] = {}
    for r in ok:
        por_layout[r.layout] = por_layout.get(r.layout, 0) + 1

    print(f"\n{total} linhas de {len(ok)} PDF(s) -> {args.saida.resolve()}")
    print("Layouts: " + ", ".join(f"{k}={v}" for k, v in sorted(por_layout.items())))
    if ok:
        media = total / len(ok)
        print(f"Media de {media:.1f} linhas por PDF "
              f"(min {min(len(r.linhas) for r in ok)}, max {max(len(r.linhas) for r in ok)})")

    if divergentes:
        print(f"\nAviso: {len(divergentes)} PDF(s) com data interna diferente do nome do arquivo:")
        for r in divergentes[:10]:
            print(f"  {r.arquivo} -> data no documento: {r.data}")

    # o site ja publicou o mesmo PDF sob dois dias diferentes; nesse caso um
    # dia fica sem cotacao e o outro aparece em dobro no CSV.
    por_data: dict[str, list[str]] = {}
    for r in ok:
        por_data.setdefault(r.data, []).append(str(r.arquivo))
    repetidas = {d: v for d, v in por_data.items() if len(v) > 1}
    if repetidas:
        print(f"\nAviso: {len(repetidas)} data(s) presente(s) em mais de um PDF:")
        for d, v in sorted(repetidas.items()):
            print(f"  {d}: {', '.join(v)}")

    if falhas:
        destino = args.falhas or args.saida.with_name(args.saida.stem + "_falhas.csv")
        with destino.open("w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(["arquivo", "layout", "motivo"])
            for r in falhas:
                w.writerow([r.arquivo, r.layout, r.erro])
        print(f"\n{len(falhas)} PDF(s) sem dados. Detalhes em {destino.resolve()}")
        motivos: dict[str, int] = {}
        for r in falhas:
            motivos[r.erro] = motivos.get(r.erro, 0) + 1
        for motivo, n in sorted(motivos.items(), key=lambda kv: -kv[1]):
            print(f"  {n:3d}x {motivo}")

    if args.resumo and total:
        todas = [linha for r in ok for linha in r.linhas]
        print("\nLinhas por grupo:")
        cont: dict[str, int] = {}
        for linha in todas:
            cont[linha.grupo or "(sem grupo)"] = cont.get(linha.grupo or "(sem grupo)", 0) + 1
        for g, n in sorted(cont.items(), key=lambda kv: -kv[1]):
            print(f"  {g:12s} {n:7d}")
        print(f"\nProdutos distintos: {len({l.produto for l in todas})}")
        print(f"Periodo: {min(l.data for l in todas)} a {max(l.data for l in todas)}")
        fora = [l for l in todas if None not in (l.preco_minimo, l.preco_comum, l.preco_maximo)
                and not (l.preco_minimo <= l.preco_comum <= l.preco_maximo)]
        print(f"Linhas com minimo<=comum<=maximo violado: {len(fora)} "
              f"({100 * len(fora) / len(todas):.2f}%)")

    return 0 if not falhas else 2


if __name__ == "__main__":
    sys.exit(main())
