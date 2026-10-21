"""Métricas de cada modelo por série (CEASA x produto) e por produto (todas as CEASAs juntas).

Uso (de dentro da pasta mlops):
    python docs/gerar_metricas_por_produto.py <run_id> [modelo_em_producao]

Saída (";" e vírgula decimal, para abrir direto no Excel):
    docs/metricas_por_serie.csv    uma linha por CEASA x produto x horizonte x modelo
    docs/metricas_por_produto.csv  uma linha por produto x horizonte x modelo (as 5 CEASAs juntas)

Atenção: numa série e num horizonte só há uma previsão por corte (13 cortes), então as métricas
por série são bem mais instáveis que as gerais. Para comparar modelos, prefira "3, 7 e 14".
"""
import sys
from pathlib import Path

import numpy as np
import pandas as pd
from google.cloud import bigquery

RUN = sys.argv[1]
PRODUCAO = sys.argv[2] if len(sys.argv) > 2 else "Chronos2"
PASTA = Path(__file__).resolve().parent

cli = bigquery.Client(project="pdm-ceasa")
prev = cli.query(f"""
    SELECT unique_id, modelo, cutoff, ds, horizonte, y, yhat
    FROM mlops.previsoes_cv WHERE run_id = '{RUN}'
""").to_dataframe()
prev["cutoff"] = pd.to_datetime(prev["cutoff"])
primeiro, ultimo = prev["cutoff"].min(), prev["cutoff"].max()

# Escala do MASE: erro médio do "repete ontem" nos 3 anos antes do 1º corte, por série.
escala = cli.query(f"""
    WITH s AS (
      SELECT CONCAT(ceasa, '__', produto_canonico) AS unique_id,
             ABS(preco_comum - LAG(preco_comum) OVER (PARTITION BY ceasa, produto_canonico ORDER BY data)) AS dif
      FROM silver.ceasa_unificado
      WHERE data BETWEEN DATE_SUB(DATE '{primeiro.date()}', INTERVAL 3 YEAR) AND DATE '{primeiro.date()}'
    )
    SELECT unique_id, AVG(dif) AS escala FROM s GROUP BY unique_id
""").to_dataframe()
# Preço no dia do corte: base para medir a variação real e a prevista.
corte = cli.query(f"""
    SELECT CONCAT(ceasa, '__', produto_canonico) AS unique_id, data AS cutoff, preco_comum AS y_corte
    FROM silver.ceasa_unificado WHERE data BETWEEN DATE '{primeiro.date()}' AND DATE '{ultimo.date()}'
""").to_dataframe()
corte["cutoff"] = pd.to_datetime(corte["cutoff"])
prev = prev.merge(escala, on="unique_id", how="left").merge(corte, on=["unique_id", "cutoff"], how="left")
partes = prev["unique_id"].str.split("__", n=1)
prev["ceasa"], prev["produto"] = partes.str[0], partes.str[1]


def r2(real, previsto):
    sst = ((real - real.mean()) ** 2).sum()
    return 1 - ((real - previsto) ** 2).sum() / sst if sst > 0 else np.nan   # preço constante: R² indefinido


def metricas(g: pd.DataFrame) -> pd.Series:
    e = g["yhat"] - g["y"]
    return pd.Series({
        "n": len(g),
        "MAE": e.abs().mean(),
        "RMSE": np.sqrt((e**2).mean()),
        "MAPE_%": (e.abs() / g["y"]).mean() * 100,
        "sMAPE_%": (2 * e.abs() / (g["y"].abs() + g["yhat"].abs())).mean() * 100,
        "WAPE_%": e.abs().sum() / g["y"].sum() * 100,
        "MASE": (e.abs() / g["escala"]).replace([np.inf, -np.inf], np.nan).mean(),
        "R2": r2(g["y"], g["yhat"]),
        "R2_variacao": r2(g["y"] - g["y_corte"], g["yhat"] - g["y_corte"]),
        "Vies": e.mean(),
    })


def tabela(chaves: list[str]) -> pd.DataFrame:
    blocos = []
    for horizonte, g in [("3, 7 e 14", prev), *[(str(h), prev[prev["horizonte"] == h]) for h in (3, 7, 14)]]:
        m = g.groupby([*chaves, "modelo"]).apply(metricas, include_groups=False).reset_index()
        naive = m[m["modelo"] == "Naive"].set_index(chaves)[["MAE", "RMSE"]].add_suffix("_naive")
        m = m.join(naive, on=chaves)
        m["U_Theil"] = m["RMSE"] / m["RMSE_naive"]
        m["ganho_MAE_vs_Naive_%"] = (1 - m["MAE"] / m["MAE_naive"]) * 100
        m["posicao_por_MAE"] = m.groupby(chaves)["MAE"].rank(method="min").astype(int)
        blocos.append(m.drop(columns=["MAE_naive", "RMSE_naive"]).assign(horizonte_dias=horizonte))
    out = pd.concat(blocos, ignore_index=True)
    out["n"] = out["n"].astype(int)
    out["em_producao"] = np.where(out["modelo"] == PRODUCAO, "sim", "")
    out.insert(out.columns.get_loc("produto") + 1, "produto_nome", out["produto"].str.replace("_", " ").str.capitalize())
    colunas = [*chaves, "produto_nome", "horizonte_dias", "modelo", "em_producao", "posicao_por_MAE", "n", "MAE", "RMSE",
               "MAPE_%", "sMAPE_%", "WAPE_%", "MASE", "R2", "R2_variacao", "Vies", "U_Theil", "ganho_MAE_vs_Naive_%"]
    return out[colunas].sort_values([*chaves, "horizonte_dias", "posicao_por_MAE"])


def salvar(df: pd.DataFrame, nome: str) -> Path:
    caminho = PASTA / nome
    df.to_csv(caminho, index=False, sep=";", decimal=",", encoding="utf-8-sig", float_format="%.4f")
    return caminho


por_serie = tabela(["ceasa", "produto"])
por_produto = tabela(["produto"])
print(salvar(por_serie, "metricas_por_serie.csv"), len(por_serie), "linhas")
print(salvar(por_produto, "metricas_por_produto.csv"), len(por_produto), "linhas")

# Resumo: em quantas séries o modelo em produção ganha do Naive (3, 7 e 14 dias juntos)
geral = por_serie[(por_serie["horizonte_dias"] == "3, 7 e 14") & (por_serie["modelo"] == PRODUCAO)]
print(f"\n{PRODUCAO} ganha do Naive em {int((geral['ganho_MAE_vs_Naive_%'] > 0).sum())} de {len(geral)} séries")
print(geral.groupby("ceasa")["ganho_MAE_vs_Naive_%"].apply(lambda s: f"{(s > 0).sum()}/{len(s)}").to_string())
melhor = por_serie[(por_serie["horizonte_dias"] == "3, 7 e 14") & (por_serie["posicao_por_MAE"] == 1)]
print("\nmodelo com menor MAE por série:", melhor["modelo"].value_counts().to_dict())
prod = por_produto[(por_produto["horizonte_dias"] == "3, 7 e 14") & (por_produto["modelo"] == PRODUCAO)]
print("\nganho do", PRODUCAO, "sobre o Naive por produto (5 CEASAs juntas):")
print(prod.set_index("produto_nome")["ganho_MAE_vs_Naive_%"].sort_values(ascending=False).round(1).to_string())
