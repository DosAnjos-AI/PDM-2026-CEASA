"""Calcula o bloco de metricas de demo (mae_demo, mse_demo, rmse_demo,
n_obs_demo) para os 6 modelos e grava o resultado em
pdm-ceasa.metricas.comparacao_modelos.

Faz: roda sql/consultas/metricas/02_previsoes_demo.sql via "bq query" e
captura a saida em memoria; le, so leitura,
~/Dropbox/PDM/recorte/cotacoes_recorte_demo.csv; normaliza produto com a
mesma regra da Silver; casa previsao com observado por
(produto, classe, data); calcula mae/mse/rmse/n por modelo; grava os 4
valores via UPDATE em pdm-ceasa.metricas.comparacao_modelos (executado via
"bq query"); imprime um resumo por modelo (casados/nao casados, metricas).

Nao faz: nao contem CREATE MODEL nem CREATE OR REPLACE MODEL -- nao
retreina nada. Nao grava o recorte em disco nem em nenhuma tabela do
BigQuery -- o CSV e lido e mantido so em memoria, e a unica escrita no
BigQuery e o UPDATE das 4 colunas de demo. Nao calcula R2 no bloco de demo
(decisao do prompt: poucas observacoes tornariam o R2 enganoso).
"""

from __future__ import annotations

import csv
import io
import re
import statistics
import subprocess
import unicodedata
from pathlib import Path

RAIZ_REPO = Path(__file__).resolve().parent.parent
SQL_PREVISOES = RAIZ_REPO / "sql" / "consultas" / "metricas" / "02_previsoes_demo.sql"
RECORTE_CSV = Path.home() / "Dropbox" / "PDM" / "recorte" / "cotacoes_recorte_demo.csv"
TABELA_METRICAS = "pdm-ceasa.metricas.comparacao_modelos"
DATAS_DEMO = {"2026-09-01", "2026-09-03", "2026-09-04"}

MODELOS = [
    ("bronze", "regressao_linear"),
    ("bronze", "regressao_arvore"),
    ("bronze", "serie_arima"),
    ("silver", "regressao_linear"),
    ("silver", "regressao_arvore"),
    ("silver", "serie_arima"),
]


def normaliza_produto(valor: str) -> str:
    """Reproduz em Python a normalizacao de produto da Silver (SQL):
    TRIM, colapso de espacos multiplos, remocao de acentos (NFD),
    minuscula, espaco -> "_"."""
    valor = valor.strip()
    valor = re.sub(r" +", " ", valor)
    valor = unicodedata.normalize("NFD", valor)
    valor = "".join(c for c in valor if not unicodedata.combining(c))
    valor = valor.lower()
    return valor.replace(" ", "_")


def roda_previsoes_demo() -> list[dict]:
    """Executa sql/consultas/metricas/02_previsoes_demo.sql via bq CLI e
    devolve as linhas como lista de dicts. So leitura de modelo ja
    treinado (ML.PREDICT / ML.FORECAST) -- nao grava nada no BigQuery."""
    comando = ["bq", "query", "--use_legacy_sql=false", "--format=csv", "--max_rows=50000"]
    resultado = subprocess.run(
        comando,
        stdin=SQL_PREVISOES.open("r", encoding="utf-8"),
        capture_output=True,
        text=True,
        check=True,
    )
    leitor = csv.DictReader(io.StringIO(resultado.stdout))
    return list(leitor)


def le_observado_recorte() -> tuple[dict, int, int]:
    """Le, so leitura, o recorte local e devolve um dict
    {(produto_normalizado, classe, data): preco_comum medio}, o total de
    linhas lidas e o numero de chaves com mais de uma linha (duplicata)."""
    observado: dict[tuple[str, int, str], list[float]] = {}
    total_linhas = 0
    with RECORTE_CSV.open("r", encoding="utf-8", newline="") as arquivo:
        leitor = csv.DictReader(arquivo)
        for linha in leitor:
            data = linha["data"]
            if data not in DATAS_DEMO:
                continue
            total_linhas += 1
            chave = (
                normaliza_produto(linha["produto"]),
                int(linha["classe"]),
                data,
            )
            observado.setdefault(chave, []).append(float(linha["preco_comum"]))

    duplicatas = sum(1 for valores in observado.values() if len(valores) > 1)
    medias = {chave: statistics.mean(valores) for chave, valores in observado.items()}
    return medias, total_linhas, duplicatas


def calcula_metricas(previsoes: list[dict], observado: dict) -> dict:
    """Casa previsao com observado por (produto, classe, data) e calcula
    mae_demo/mse_demo/rmse_demo/n_obs_demo por (camada, modelo). Nao
    calcula R2 -- fora de escopo do bloco de demo."""
    por_modelo: dict[tuple[str, str], dict] = {
        (camada, modelo): {"erros_abs": [], "erros_sq": [], "casaram": 0, "nao_casaram": 0}
        for camada, modelo in MODELOS
    }

    for linha in previsoes:
        camada = linha["camada"]
        modelo = linha["modelo"]
        chave_modelo = (camada, modelo)
        if chave_modelo not in por_modelo:
            continue

        chave = (
            normaliza_produto(linha["produto"]),
            int(linha["classe"]),
            linha["data"],
        )
        acumulador = por_modelo[chave_modelo]
        if chave not in observado:
            acumulador["nao_casaram"] += 1
            continue

        preco_previsto = float(linha["preco_previsto"])
        preco_observado = observado[chave]
        erro = preco_observado - preco_previsto
        acumulador["erros_abs"].append(abs(erro))
        acumulador["erros_sq"].append(erro * erro)
        acumulador["casaram"] += 1

    resultado = {}
    for chave_modelo, acumulador in por_modelo.items():
        n = acumulador["casaram"]
        if n == 0:
            resultado[chave_modelo] = {
                "mae_demo": None,
                "mse_demo": None,
                "rmse_demo": None,
                "n_obs_demo": 0,
                "casaram": 0,
                "nao_casaram": acumulador["nao_casaram"],
            }
            continue
        mae = statistics.mean(acumulador["erros_abs"])
        mse = statistics.mean(acumulador["erros_sq"])
        resultado[chave_modelo] = {
            "mae_demo": mae,
            "mse_demo": mse,
            "rmse_demo": mse ** 0.5,
            "n_obs_demo": n,
            "casaram": n,
            "nao_casaram": acumulador["nao_casaram"],
        }
    return resultado


def grava_metricas(metricas: dict) -> None:
    """Gera um UPDATE por modelo e executa tudo numa unica chamada ao bq
    CLI (script multi-statement). Grava so os 4 valores agregados --
    nenhum dado do recorte entra na instrucao alem dos numeros finais."""
    comandos = []
    for (camada, modelo), valores in metricas.items():
        mae = "NULL" if valores["mae_demo"] is None else repr(valores["mae_demo"])
        mse = "NULL" if valores["mse_demo"] is None else repr(valores["mse_demo"])
        rmse = "NULL" if valores["rmse_demo"] is None else repr(valores["rmse_demo"])
        n = valores["n_obs_demo"]
        comandos.append(
            f"UPDATE `{TABELA_METRICAS}`\n"
            f"SET mae_demo = {mae}, mse_demo = {mse}, rmse_demo = {rmse}, n_obs_demo = {n}\n"
            f"WHERE camada = '{camada}' AND modelo = '{modelo}';"
        )
    script_sql = "\n".join(comandos)
    subprocess.run(
        ["bq", "query", "--use_legacy_sql=false"],
        input=script_sql,
        capture_output=True,
        text=True,
        check=True,
    )


def main() -> None:
    previsoes = roda_previsoes_demo()
    print(f"[FATO] previsoes trazidas do BigQuery: {len(previsoes)} linhas")

    observado, total_linhas_recorte, duplicatas = le_observado_recorte()
    print(
        f"[FATO] recorte lido (so leitura): {total_linhas_recorte} linhas nas 3 datas de demo, "
        f"{len(observado)} chaves (produto, classe, data) distintas, "
        f"{duplicatas} chaves com mais de uma linha (media aplicada)"
    )

    metricas = calcula_metricas(previsoes, observado)

    print("\n[FATO] resumo por modelo:")
    for camada, modelo in MODELOS:
        valores = metricas[(camada, modelo)]
        print(
            f"  {camada}/{modelo}: casaram={valores['casaram']} "
            f"nao_casaram={valores['nao_casaram']} "
            f"n_obs_demo={valores['n_obs_demo']} "
            f"mae_demo={valores['mae_demo']} "
            f"mse_demo={valores['mse_demo']} "
            f"rmse_demo={valores['rmse_demo']}"
        )

    grava_metricas(metricas)
    print(f"\n[FATO] UPDATE executado em {TABELA_METRICAS} para os 6 modelos")


if __name__ == "__main__":
    main()
