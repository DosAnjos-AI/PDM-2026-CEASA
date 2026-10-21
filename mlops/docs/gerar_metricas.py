"""Métricas padrão de séries temporais para cada modelo, a partir do walk-forward de uma execução.

Grava um CSV em formato longo (período x horizonte x modelo), com ";" e vírgula decimal para abrir
direto no Excel, e imprime as tabelas principais.

Uso (de dentro da pasta mlops):
    python docs/gerar_metricas.py <run_id> docs/metricas_modelos.csv

Métricas: MAE, RMSE, MAPE, sMAPE, WAPE, MASE (escala = erro médio do Naive de 1 dia nos 3 anos
antes do 1º corte, por série), R², viés (média de previsto - real), U de Theil (RMSE do modelo /
RMSE do Naive) e ganho de MAE sobre o Naive.
"""
import sys

import numpy as np
import pandas as pd
from google.cloud import bigquery

RUN = sys.argv[1]
SAIDA = sys.argv[2]
pd.set_option("display.width", 250)
cli = bigquery.Client(project="pdm-ceasa")

prev = cli.query(f"""
    SELECT unique_id, modelo, cutoff, ds, horizonte, y, yhat
    FROM mlops.previsoes_cv WHERE run_id = '{RUN}'
""").to_dataframe()
prev["cutoff"] = pd.to_datetime(prev["cutoff"])
cortes = sorted(prev["cutoff"].unique())
inicio_holdout = cortes[-4]
prev["periodo"] = np.where(prev["cutoff"] >= inicio_holdout, "holdout", "selecao")

# Escala do MASE: erro médio do Naive de 1 dia no período de treino de cada série (3 anos antes do 1º corte).
escala = cli.query(f"""
    WITH s AS (
      SELECT CONCAT(ceasa, '__', produto_canonico) AS unique_id, data,
             ABS(preco_comum - LAG(preco_comum) OVER (PARTITION BY ceasa, produto_canonico ORDER BY data)) AS dif
      FROM silver.ceasa_unificado
      WHERE data BETWEEN DATE_SUB(DATE '{pd.Timestamp(cortes[0]).date()}', INTERVAL 3 YEAR)
                     AND DATE '{pd.Timestamp(cortes[0]).date()}'
    )
    SELECT unique_id, AVG(dif) AS escala FROM s GROUP BY unique_id
""").to_dataframe()
prev = prev.merge(escala, on="unique_id", how="left")


def metricas(g: pd.DataFrame) -> pd.Series:
    e = g["yhat"] - g["y"]
    sq_total = ((g["y"] - g["y"].mean()) ** 2).sum()
    escalados = (e.abs() / g["escala"]).replace([np.inf, -np.inf], np.nan)
    return pd.Series({
        "n": len(g),
        "MAE": e.abs().mean(),
        "RMSE": np.sqrt((e**2).mean()),
        "MAPE_%": (e.abs() / g["y"].abs()).mean() * 100,
        "sMAPE_%": (2 * e.abs() / (g["y"].abs() + g["yhat"].abs())).mean() * 100,
        "WAPE_%": e.abs().sum() / g["y"].abs().sum() * 100,
        "MASE": escalados.mean(),
        "R2": 1 - (e**2).sum() / sq_total,
        "Vies_ME": e.mean(),
    })


partes = []
for periodo, base in [("todos os cortes", prev), ("holdout", prev[prev["periodo"] == "holdout"])]:
    for horizonte, g in [(0, base), *[(h, base[base["horizonte"] == h]) for h in (3, 7, 14)]]:
        m = g.groupby("modelo").apply(metricas, include_groups=False).reset_index()
        naive = m.set_index("modelo").loc["Naive"]
        m["U_Theil"] = m["RMSE"] / naive["RMSE"]
        m["ganho_MAE_vs_Naive_%"] = (1 - m["MAE"] / naive["MAE"]) * 100
        partes.append(m.assign(periodo=periodo, horizonte_dias=horizonte if horizonte else "3, 7 e 14"))

tab = pd.concat(partes, ignore_index=True)
colunas = ["periodo", "horizonte_dias", "modelo", "n", "MAE", "RMSE", "MAPE_%", "sMAPE_%", "WAPE_%", "MASE",
           "R2", "Vies_ME", "U_Theil", "ganho_MAE_vs_Naive_%"]
tab = tab[colunas].sort_values(["periodo", "horizonte_dias", "MAE"])
tab["n"] = tab["n"].astype(int)
tab.to_csv(SAIDA, index=False, sep=";", decimal=",", encoding="utf-8-sig", float_format="%.4f")

print("cortes:", pd.Timestamp(cortes[0]).date(), "->", pd.Timestamp(cortes[-1]).date(), "| holdout desde", pd.Timestamp(inicio_holdout).date())
print("series sem escala de MASE:", int(prev["escala"].isna().sum()), "| escala zero:", int((prev["escala"] == 0).sum()))
for periodo in ["todos os cortes", "holdout"]:
    t = tab[(tab["periodo"] == periodo) & (tab["horizonte_dias"] == "3, 7 e 14")].drop(columns=["periodo", "horizonte_dias"])
    print(f"\n=== {periodo.upper()} (3, 7 e 14 dias juntos) ===")
    print(t.round(4).to_string(index=False))
for h in (3, 7, 14):
    t = tab[(tab["periodo"] == "todos os cortes") & (tab["horizonte_dias"] == h)]
    print(f"\n=== horizonte {h} dias ===")
    print(t[["modelo", "MAE", "RMSE", "MAPE_%", "MASE", "U_Theil", "ganho_MAE_vs_Naive_%"]].round(4).to_string(index=False))
