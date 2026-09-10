#!/usr/bin/env python3
"""
Scraper das cotacoes diarias da CEASA-GO.

Percorre a hierarquia do site:
    cotacoes-diarias/  ->  paginas por ano  ->  paginas por mes  ->  PDFs diarios

Os slugs das paginas de mes nao seguem um padrao unico
(ex.: "cotacao-diaria-junho", "cotacoes-diarias-marco-de-2024",
"cotacoes-diarias-janeiro-2024-2"), entao os links sao sempre seguidos a
partir do HTML em vez de montados por template. O mesmo vale para o nome dos
PDFs ("03-06-2024.pdf", "02_01_2024-b10.pdf").

Dependencias: requests e beautifulsoup4. Nao depende de binario externo,
roda igual em Linux e Windows.

Uso:
    python3 ceasa_scraper.py                       # 2024 ate hoje, salva em ./cotacoes
    python3 ceasa_scraper.py --start-year 2019
    python3 ceasa_scraper.py --dry-run             # so lista o que baixaria
"""

from __future__ import annotations

import argparse
import csv
import re
import sys
import threading
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urljoin, urlparse

import requests
from bs4 import BeautifulSoup
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

RAIZ = "https://goias.gov.br/ceasa/cotacoes-diarias/"
UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

MESES = {
    "janeiro": 1, "fevereiro": 2, "marco": 3, "abril": 4, "maio": 5, "junho": 6,
    "julho": 7, "agosto": 8, "setembro": 9, "outubro": 10, "novembro": 11, "dezembro": 12,
}

RE_ANO_URL = re.compile(r"cotacoes?-diarias?-(\d{4})/?$")
RE_DATA_ARQ = re.compile(r"(\d{2})[-_.](\d{2})[-_.](\d{4})")
RE_DATA_TXT = re.compile(r"(\d{1,2})\s*[/-]\s*(\d{1,2})\s*[/-]\s*(\d{2,4})")
RE_CAMINHO_UPLOAD = re.compile(r"/uploads/sites/\d+/(\d{4})/(\d{2})/")


def sem_acento(texto: str) -> str:
    nfkd = unicodedata.normalize("NFKD", texto)
    return "".join(c for c in nfkd if not unicodedata.combining(c)).lower()


@dataclass(frozen=True)
class Doc:
    url: str
    ano: int
    mes: int
    dia: int | None

    @property
    def destino_rel(self) -> Path:
        if self.dia:
            nome = f"{self.ano:04d}-{self.mes:02d}-{self.dia:02d}.pdf"
        else:
            # sem data reconhecivel: preserva o nome original para nao colidir
            nome = Path(urlparse(self.url).path).name
        return Path(f"{self.ano:04d}") / f"{self.mes:02d}" / nome


class Scraper:
    def __init__(self, saida: Path, delay: float = 0.5, timeout: int = 60, workers: int = 4):
        self.saida = saida
        self.delay = delay
        self.timeout = timeout
        self.workers = workers
        self.sessao = requests.Session()
        self.sessao.headers.update({"User-Agent": UA, "Accept-Language": "pt-BR,pt;q=0.9"})
        retry = Retry(
            total=4,
            backoff_factor=1.5,
            status_forcelist=(429, 500, 502, 503, 504),
            allowed_methods=frozenset(["GET", "HEAD"]),
        )
        adapter = HTTPAdapter(max_retries=retry, pool_maxsize=max(workers, 10))
        self.sessao.mount("https://", adapter)
        self.sessao.mount("http://", adapter)
        self._trava = threading.Lock()
        self._ultimo_acesso = 0.0

    # ------------------------------------------------------------------ HTTP

    def _aguarda(self) -> None:
        """Espaca as requisicoes para nao martelar o servidor."""
        if self.delay <= 0:
            return
        with self._trava:
            espera = self._ultimo_acesso + self.delay - time.monotonic()
            if espera > 0:
                time.sleep(espera)
            self._ultimo_acesso = time.monotonic()

    def sopa(self, url: str) -> BeautifulSoup | None:
        self._aguarda()
        try:
            r = self.sessao.get(url, timeout=self.timeout)
            r.raise_for_status()
        except requests.RequestException as e:
            print(f"  ! falha ao abrir {url}: {e}", file=sys.stderr)
            return None
        return BeautifulSoup(r.text, "html.parser")

    @staticmethod
    def conteudo(sopa: BeautifulSoup):
        """Area util da pagina; fora dela so ha menu/rodape repetidos."""
        return sopa.select_one("section.entry-content") or sopa

    # --------------------------------------------------------------- crawling

    def anos(self, inicio: int, fim: int) -> list[tuple[int, str]]:
        sopa = self.sopa(RAIZ)
        if sopa is None:
            return []
        achados: dict[int, str] = {}
        for a in self.conteudo(sopa).select("a[href]"):
            url = urljoin(RAIZ, a["href"].replace("/ceasa//", "/ceasa/"))
            m = RE_ANO_URL.search(urlparse(url).path)
            if m:
                ano = int(m.group(1))
                if inicio <= ano <= fim:
                    achados.setdefault(ano, url)
        # a propria pagina do ano corrente costuma ficar so no menu lateral
        return sorted(achados.items())

    def meses(self, ano: int, url_ano: str) -> list[tuple[int, str]]:
        sopa = self.sopa(url_ano)
        if sopa is None:
            return []
        achados: dict[int, str] = {}
        for a in self.conteudo(sopa).select("a[href]"):
            url = urljoin(url_ano, a["href"].replace("/ceasa//", "/ceasa/"))
            if urlparse(url).path.rstrip("/") == urlparse(url_ano).path.rstrip("/"):
                continue  # link para a propria pagina do ano
            if url.lower().endswith(".pdf"):
                continue
            # o texto do link varia muito ("Cotacoes Diarias - Janeiro 2024",
            # "Janeiro de 2019"), entao o unico criterio e o nome do mes.
            texto = sem_acento(a.get_text(" ", strip=True))
            for nome, num in MESES.items():
                # limites so contra letras: o site escreve "Novembro2024" sem espaco
                if re.search(rf"(?<![a-z]){nome}(?![a-z])", texto):
                    achados.setdefault(num, url)
                    break
        return sorted(achados.items())

    def pdfs(self, ano: int, mes: int, url_mes: str) -> list[Doc]:
        sopa = self.sopa(url_mes)
        if sopa is None:
            return []
        docs: dict[str, Doc] = {}
        for a in self.conteudo(sopa).select("a[href]"):
            url = urljoin(url_mes, a["href"])
            if not urlparse(url).path.lower().endswith(".pdf"):
                continue
            docs.setdefault(url, self._data_do_pdf(url, a.get_text(" ", strip=True), ano, mes))
        return list(docs.values())

    @staticmethod
    def _data_do_pdf(url: str, texto: str, ano_pag: int, mes_pag: int) -> Doc:
        """Deduz a data do documento: nome do arquivo -> texto do link -> pasta."""
        nome = Path(urlparse(url).path).name
        m = RE_DATA_ARQ.search(nome)
        if m:
            dia, mes, ano = (int(x) for x in m.groups())
            if 1 <= dia <= 31 and 1 <= mes <= 12:
                return Doc(url, ano, mes, dia)

        m = RE_DATA_TXT.search(texto)
        if m:
            dia, mes, ano = (int(x) for x in m.groups())
            ano = ano + 2000 if ano < 100 else ano
            if 1 <= dia <= 31 and 1 <= mes <= 12:
                return Doc(url, ano, mes, dia)

        m = re.search(r"\b([0-3]?\d)\b", texto)
        dia = int(m.group(1)) if m and 1 <= int(m.group(1)) <= 31 else None

        p = RE_CAMINHO_UPLOAD.search(urlparse(url).path)
        if p:
            return Doc(url, int(p.group(1)), int(p.group(2)), dia)
        return Doc(url, ano_pag, mes_pag, dia)

    def coletar(self, inicio: int, fim: int) -> list[Doc]:
        vistos: set[str] = set()
        docs: list[Doc] = []
        anos = self.anos(inicio, fim)
        if not anos:
            print("Nenhuma pagina de ano encontrada (site fora do ar ou layout mudou?).", file=sys.stderr)
            return []
        print(f"Anos encontrados: {', '.join(str(a) for a, _ in anos)}")
        for ano, url_ano in anos:
            meses = self.meses(ano, url_ano)
            print(f"\n{ano}: {len(meses)} mes(es)")
            for mes, url_mes in meses:
                achados = [d for d in self.pdfs(ano, mes, url_mes) if d.url not in vistos]
                vistos.update(d.url for d in achados)
                docs.extend(achados)
                print(f"  {ano}-{mes:02d}: {len(achados):3d} PDF(s)  <- {url_mes}")
        return docs

    # ------------------------------------------------------------- download

    def baixar(self, doc: Doc) -> tuple[Doc, str, int]:
        destino = self.saida / doc.destino_rel
        if destino.exists() and destino.stat().st_size > 0:
            return doc, "existente", destino.stat().st_size

        destino.parent.mkdir(parents=True, exist_ok=True)
        parcial = destino.with_suffix(destino.suffix + ".part")
        self._aguarda()
        try:
            with self.sessao.get(url := doc.url, timeout=self.timeout, stream=True) as r:
                r.raise_for_status()
                primeiro = True
                with parcial.open("wb") as fh:
                    for pedaco in r.iter_content(64 * 1024):
                        if primeiro:
                            if not pedaco.startswith(b"%PDF"):
                                parcial.unlink(missing_ok=True)
                                return doc, "nao-e-pdf", 0
                            primeiro = False
                        fh.write(pedaco)
        except requests.RequestException as e:
            parcial.unlink(missing_ok=True)
            return doc, f"erro: {e.__class__.__name__}", 0

        parcial.replace(destino)  # so vira arquivo final quando completo
        return doc, "baixado", destino.stat().st_size

    def baixar_todos(self, docs: list[Doc]) -> list[tuple[Doc, str, int]]:
        resultados: list[tuple[Doc, str, int]] = []
        with ThreadPoolExecutor(max_workers=self.workers) as pool:
            futuros = {pool.submit(self.baixar, d): d for d in docs}
            for i, fut in enumerate(as_completed(futuros), 1):
                doc, estado, tam = fut.result()
                resultados.append((doc, estado, tam))
                marca = {"baixado": "+", "existente": "=", "nao-e-pdf": "?"}.get(estado, "!")
                print(f"[{i:4d}/{len(docs)}] {marca} {doc.destino_rel}  ({estado})")
        return resultados


def escrever_manifesto(caminho: Path, resultados: list[tuple[Doc, str, int]]) -> None:
    caminho.parent.mkdir(parents=True, exist_ok=True)
    with caminho.open("w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh)
        w.writerow(["data", "ano", "mes", "dia", "arquivo", "url", "status", "bytes"])
        for doc, estado, tam in sorted(resultados, key=lambda r: str(r[0].destino_rel)):
            data = f"{doc.ano:04d}-{doc.mes:02d}-{doc.dia:02d}" if doc.dia else ""
            w.writerow([data, doc.ano, doc.mes, doc.dia or "", doc.destino_rel, doc.url, estado, tam])


def main() -> int:
    p = argparse.ArgumentParser(description="Baixa as cotacoes diarias (PDF) da CEASA-GO.")
    p.add_argument("--start-year", type=int, default=2024, help="ano inicial (padrao: 2024)")
    p.add_argument("--end-year", type=int, default=2100, help="ano final (padrao: sem limite)")
    p.add_argument("-o", "--out", type=Path, default=Path("cotacoes"), help="pasta de destino")
    p.add_argument("--delay", type=float, default=0.5, help="segundos entre requisicoes (padrao: 0.5)")
    p.add_argument("--workers", type=int, default=4, help="downloads simultaneos (padrao: 4)")
    p.add_argument("--timeout", type=int, default=60, help="timeout HTTP em segundos")
    p.add_argument("--dry-run", action="store_true", help="apenas lista os PDFs, sem baixar")
    p.add_argument("--manifest", type=Path, default=None, help="CSV de saida (padrao: <out>/manifesto.csv)")
    args = p.parse_args()

    s = Scraper(args.out, delay=args.delay, timeout=args.timeout, workers=args.workers)
    docs = s.coletar(args.start_year, args.end_year)
    print(f"\nTotal: {len(docs)} PDF(s) de {args.start_year} a {args.end_year}.")
    if not docs:
        return 1

    if args.dry_run:
        for d in sorted(docs, key=lambda d: str(d.destino_rel)):
            print(f"{d.destino_rel}\t{d.url}")
        return 0

    resultados = s.baixar_todos(docs)
    manifesto = args.manifest or (args.out / "manifesto.csv")
    escrever_manifesto(manifesto, resultados)

    contagem: dict[str, int] = {}
    for _, estado, _ in resultados:
        chave = estado.split(":")[0]
        contagem[chave] = contagem.get(chave, 0) + 1
    print("\nResumo: " + ", ".join(f"{k}={v}" for k, v in sorted(contagem.items())))
    print(f"Arquivos em: {args.out.resolve()}")
    print(f"Manifesto:   {manifesto.resolve()}")
    return 0 if contagem.get("erro", 0) == 0 else 2


if __name__ == "__main__":
    sys.exit(main())
