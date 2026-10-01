"""
Pecas compartilhadas pelos coletores de outras CEASAs (SP, MS, MG, ES).

Todos produzem um CSV com o mesmo esquema (COLUNAS), para que a carga na
Bronze seja igual para qualquer fonte. Coluna que a fonte nao publica fica
vazia; nenhum valor e inferido.

Dependencias: requests e beautifulsoup4 (mesmas do ceasa_scraper.py).
"""

from __future__ import annotations

import csv
import os
import re
import sys
import threading
import time
from http.cookiejar import DefaultCookiePolicy
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

# Pasta onde ficam brutos e CSVs; padrao: raiz do repositorio (nada disso e versionado)
DIR_DADOS = Path(os.environ.get("CEASA_DADOS", Path(__file__).resolve().parents[1]))

UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36"

# Esquema unico de saida, na ordem das colunas do CSV
COLUNAS = [
    "data", "ano", "mes", "dia", "fonte", "mercado", "grupo", "produto",
    "classificacao", "embalagem", "qtd_kg", "preco_minimo", "preco_comum",
    "preco_maximo", "situacao", "arquivo",
]

RE_NUMERO = re.compile(r"^-?\d{1,3}(\.\d{3})*(,\d+)?$|^-?\d+(,\d+)?$")


class Cliente:
    """Sessao HTTP com retry e espacamento minimo entre requisicoes (seguro entre threads)."""

    def __init__(self, delay: float = 0.5, timeout: int = 60, conexoes: int = 10, cookies: bool = True):
        self.delay = delay
        self.timeout = timeout
        self.sessao = requests.Session()
        if not cookies:
            # requisicoes independentes: servidor nao amarra uma consulta a anterior
            self.sessao.cookies.set_policy(DefaultCookiePolicy(allowed_domains=[]))
        self.sessao.headers.update({"User-Agent": UA, "Accept-Language": "pt-BR,pt;q=0.9"})
        retry = Retry(
            total=4,
            backoff_factor=1.5,
            status_forcelist=(429, 500, 502, 503, 504),
            allowed_methods=frozenset(["GET", "HEAD", "POST"]),
        )
        adapter = HTTPAdapter(max_retries=retry, pool_maxsize=conexoes)
        self.sessao.mount("https://", adapter)
        self.sessao.mount("http://", adapter)
        self._trava = threading.Lock()
        self._ultimo_acesso = 0.0

    def _aguarda(self) -> None:
        """Espaca as requisicoes para nao martelar o servidor."""
        if self.delay <= 0:
            return
        with self._trava:
            espera = self._ultimo_acesso + self.delay - time.monotonic()
            if espera > 0:
                time.sleep(espera)
            self._ultimo_acesso = time.monotonic()

    def get(self, url: str, **kw) -> requests.Response:
        self._aguarda()
        r = self.sessao.get(url, timeout=self.timeout, **kw)
        r.raise_for_status()
        return r

    def head(self, url: str, **kw) -> requests.Response:
        self._aguarda()
        r = self.sessao.head(url, timeout=self.timeout, allow_redirects=True, **kw)
        r.raise_for_status()
        return r

    def post(self, url: str, data, **kw) -> requests.Response:
        self._aguarda()
        r = self.sessao.post(url, data=data, timeout=self.timeout, **kw)
        r.raise_for_status()
        return r


def numero_br(texto) -> float | None:
    """'1.234,56' -> 1234.56. Texto que nao e numero ('S/C', '-', '') vira None."""
    if texto is None:
        return None
    if isinstance(texto, (int, float)):
        return float(texto)
    t = str(texto).strip()
    if not RE_NUMERO.match(t):
        return None
    return float(t.replace(".", "").replace(",", "."))


def limpa(texto) -> str:
    """Colapsa espacos internos e tira das pontas."""
    return re.sub(r"\s+", " ", str(texto or "")).strip()


def grava_atomico(destino: Path, conteudo: bytes) -> None:
    """So vira arquivo final quando completo: interrupcao nao deixa arquivo pela metade."""
    destino.parent.mkdir(parents=True, exist_ok=True)
    parcial = destino.with_suffix(destino.suffix + ".part")
    parcial.write_bytes(conteudo)
    parcial.replace(destino)


def escreve_csv(caminho: Path, linhas: list[dict]) -> None:
    """Grava ordenado, para que reexecutar sobre os mesmos brutos gere o mesmo arquivo."""
    linhas = sorted(linhas, key=lambda l: (l["data"], l["mercado"], l["grupo"], l["arquivo"], l["_ordem"]))
    caminho.parent.mkdir(parents=True, exist_ok=True)
    parcial = caminho.with_suffix(caminho.suffix + ".part")
    with parcial.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=COLUNAS, extrasaction="ignore")
        w.writeheader()
        for l in linhas:
            w.writerow({k: ("" if v is None else v) for k, v in l.items()})
    parcial.replace(caminho)


def linha(data, fonte: str, mercado: str, grupo: str, produto: str, arquivo: str, ordem: int,
          classificacao: str = "", embalagem: str = "", qtd_kg=None, preco_minimo=None,
          preco_comum=None, preco_maximo=None, situacao: str = "") -> dict:
    """Monta um registro no esquema COLUNAS. `ordem` preserva a ordem da fonte dentro do arquivo."""
    return {
        "data": data.isoformat(), "ano": data.year, "mes": data.month, "dia": data.day,
        "fonte": fonte, "mercado": mercado, "grupo": limpa(grupo), "produto": limpa(produto),
        "classificacao": limpa(classificacao), "embalagem": limpa(embalagem), "qtd_kg": qtd_kg,
        "preco_minimo": preco_minimo, "preco_comum": preco_comum, "preco_maximo": preco_maximo,
        "situacao": limpa(situacao), "arquivo": arquivo, "_ordem": ordem,
    }


def confere(linhas: list[dict], rotulo: str) -> int:
    """Conferencia minima da saida: contagem, nulos nas chaves e faixa de datas e precos."""
    if not linhas:
        print(f"{rotulo}: nenhuma linha extraida.", file=sys.stderr)
        return 1
    datas = sorted({l["data"] for l in linhas})
    sem_chave = sum(1 for l in linhas if not (l["data"] and l["produto"]))
    sem_preco = sum(1 for l in linhas if l["preco_comum"] is None)
    invertidos = sum(
        1 for l in linhas
        if None not in (l["preco_minimo"], l["preco_comum"], l["preco_maximo"])
        and not (l["preco_minimo"] <= l["preco_comum"] <= l["preco_maximo"])
    )
    precos = [l["preco_comum"] for l in linhas if l["preco_comum"] is not None]
    print(f"\n{rotulo}: {len(linhas)} linhas, {len(datas)} datas ({datas[0]} a {datas[-1]}), "
          f"{len({l['mercado'] for l in linhas})} mercado(s), {len({l['produto'] for l in linhas})} produtos")
    print(f"  sem data/produto: {sem_chave} | sem preco_comum: {sem_preco} | "
          f"fora de minimo<=comum<=maximo: {invertidos}")
    if precos:
        print(f"  preco_comum: min {min(precos)} max {max(precos)}")
    return 1 if sem_chave else 0
