"""Gera uma tabela em PNG com as métricas dos modelos para cada horizonte (3, 7 e 14 dias).

Uso (de dentro da pasta mlops):
    python docs/gerar_tabelas_png.py <run_id> [modelo_em_producao]

Saída: docs/metricas_3_dias.png, docs/metricas_7_dias.png e docs/metricas_14_dias.png.
Métricas calculadas sobre o walk-forward da execução (mlops.previsoes_cv), todos os cortes.
"""
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from google.cloud import bigquery
from matplotlib.patches import Rectangle

RUN = sys.argv[1]
PRODUCAO = sys.argv[2] if len(sys.argv) > 2 else "Chronos2"
PASTA = Path(__file__).resolve().parent

PAPEL, TINTA, SUAVE, LINHA = "#fbfaf7", "#1f2421", "#5d655f", "#d5d9d1"
FOLHA, FOLHA_CLARA, RUIM, CINZA = "#2f6b4f", "#e2eee5", "#a33a32", "#eceee9"

# ---------------------------------------------------------------- dados
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


def r2(real, previsto):
    sst = ((real - real.mean()) ** 2).sum()
    return 1 - ((real - previsto) ** 2).sum() / sst


def metricas(g: pd.DataFrame) -> pd.Series:
    e = g["yhat"] - g["y"]
    return pd.Series({
        "MAE": e.abs().mean(),
        "RMSE": np.sqrt((e**2).mean()),
        "MAPE": (e.abs() / g["y"]).mean() * 100,
        "sMAPE": (2 * e.abs() / (g["y"].abs() + g["yhat"].abs())).mean() * 100,
        "WAPE": e.abs().sum() / g["y"].sum() * 100,
        "MASE": (e.abs() / g["escala"]).mean(),
        "R2": r2(g["y"], g["yhat"]),
        "R2_var": r2(g["y"] - g["y_corte"], g["yhat"] - g["y_corte"]),
        "Vies": e.mean(),
    })


# ---------------------------------------------------------------- formatação
def br(v: float, casas: int, sinal: bool = False) -> str:
    texto = f"{v:+,.{casas}f}" if sinal else f"{v:,.{casas}f}"
    return texto.replace(",", "X").replace(".", ",").replace("X", ".").replace("-", "−")


COLUNAS = [  # chave, título, formato, critério do melhor valor
    ("MAE", "MAE\n(R$/kg)", lambda v: br(v, 3), "min"),
    ("RMSE", "RMSE\n(R$/kg)", lambda v: br(v, 3), "min"),
    ("MAPE", "MAPE", lambda v: br(v, 2) + "%", "min"),
    ("sMAPE", "sMAPE", lambda v: br(v, 2) + "%", "min"),
    ("WAPE", "WAPE", lambda v: br(v, 2) + "%", "min"),
    ("MASE", "MASE", lambda v: br(v, 2), "min"),
    ("R2", "R²", lambda v: br(v, 3), "max"),
    ("R2_var", "R² da\nvariação", lambda v: br(v, 3), "max"),
    ("Vies", "Viés\n(R$/kg)", lambda v: br(v, 3, sinal=True), "absmin"),
    ("U", "U de\nTheil", lambda v: br(v, 3), "min"),
    ("Ganho", "Ganho sobre\no Naive", lambda v: br(v, 1, sinal=True) + "%", "max"),
]


def desenhar(tab: pd.DataFrame, h: int, n: int) -> Path:
    linhas = len(tab)
    larg_modelo, larg_col = 0.175, (1 - 0.175) / len(COLUNAS)
    alt_titulo, alt_cab, alt_linha, alt_rodape = 1.25, 0.75, 0.42, 1.25
    altura = alt_titulo + alt_cab + alt_linha * linhas + alt_rodape
    fig = plt.figure(figsize=(16, altura), dpi=150)
    fig.patch.set_facecolor(PAPEL)
    ax = fig.add_axes([0.03, 0, 0.94, 1])
    ax.set_xlim(0, 1)
    ax.set_ylim(0, altura)
    ax.axis("off")

    topo = altura - 0.35
    ax.text(0, topo, f"Previsão {h} dias à frente: métricas dos modelos", fontsize=19, weight="bold",
            color=TINTA, va="top")
    ax.text(0, topo - 0.5,
            f"Walk-forward com 13 cortes ({primeiro:%d/%m/%Y} a {ultimo:%d/%m/%Y}) · 120 séries (CEASA × produto) · "
            f"preço comum em R$/kg · {n:,} previsões por modelo".replace(",", "."),
            fontsize=11.5, color=SUAVE, va="top")

    # cabeçalho
    y_cab = altura - alt_titulo
    ax.add_patch(Rectangle((0, y_cab - alt_cab), 1, alt_cab, facecolor=FOLHA, edgecolor="none"))
    ax.text(0.012, y_cab - alt_cab / 2, "Modelo", color="white", fontsize=11, weight="bold", va="center")
    for i, (_, titulo, _, _) in enumerate(COLUNAS):
        x = larg_modelo + larg_col * (i + 0.5)
        ax.text(x, y_cab - alt_cab / 2, titulo, color="white", fontsize=10, weight="bold",
                ha="center", va="center", linespacing=1.15)

    # melhor valor de cada coluna (o SeasonalNaive e o próprio Naive no ganho não concorrem)
    concorrentes = tab[tab["modelo"] != "SeasonalNaive"]
    melhores = {}
    for chave, _, _, criterio in COLUNAS:
        serie = concorrentes.set_index("modelo")[chave]
        if chave == "Ganho":
            serie = serie.drop("Naive", errors="ignore")
        melhores[chave] = {"min": serie.idxmin(), "max": serie.idxmax(), "absmin": serie.abs().idxmin()}[criterio]

    # linhas
    for j, linha in enumerate(tab.itertuples(index=False)):
        y0 = y_cab - alt_cab - alt_linha * (j + 1)
        fundo = FOLHA_CLARA if linha.modelo == PRODUCAO else (CINZA if linha.modelo == "Naive" else
                                                             (PAPEL if j % 2 == 0 else "#f4f5f0"))
        ax.add_patch(Rectangle((0, y0), 1, alt_linha, facecolor=fundo, edgecolor="none"))
        ax.plot([0, 1], [y0, y0], color=LINHA, linewidth=0.8)
        rotulo = linha.modelo + (" (produção)" if linha.modelo == PRODUCAO else
                                 " (referência)" if linha.modelo == "Naive" else "")
        ax.text(0.012, y0 + alt_linha / 2, rotulo, fontsize=11, va="center", color=TINTA,
                weight="bold" if linha.modelo in (PRODUCAO, "Naive") else "normal")
        for i, (chave, _, formato, _) in enumerate(COLUNAS):
            valor = getattr(linha, chave)
            x = larg_modelo + larg_col * (i + 0.5)
            if chave == "Ganho" and linha.modelo == "Naive":
                texto, cor, peso = "—", SUAVE, "normal"
            else:
                texto = formato(valor)
                melhor = melhores[chave] == linha.modelo
                cor = FOLHA if melhor else TINTA
                if chave == "Ganho":
                    cor = FOLHA if valor > 0 else RUIM
                    if abs(valor) < 0.05:   # arredonda para zero: sem sinal e sem cor de ganho/perda
                        texto, cor = "0,0%", SUAVE
                peso = "bold" if melhor else "normal"
            ax.text(x, y0 + alt_linha / 2, texto, fontsize=10.5, ha="center", va="center", color=cor, weight=peso)
    base = y_cab - alt_cab - alt_linha * linhas
    ax.plot([0, 1], [base, base], color=TINTA, linewidth=1.2)

    # rodapé
    ax.text(0, base - 0.22,
            "Em verde e negrito: melhor valor da coluna. MAE, RMSE e viés em R$/kg; MAPE, sMAPE e WAPE em %. "
            "MASE: erro dividido pela variação diária típica da série (a escala é de 1 dia, por isso fica acima de 1).",
            fontsize=9.5, color=SUAVE, va="top")
    ax.text(0, base - 0.52,
            "R² da variação: quanto da subida ou descida real do preço o modelo acerta (0 = o mesmo que o Naive). "
            "U de Theil: RMSE do modelo ÷ RMSE do Naive (abaixo de 1 = melhor). Viés: média de previsto − real.",
            fontsize=9.5, color=SUAVE, va="top")
    ax.text(0, base - 0.82, f"Fonte: mlops.previsoes_cv, execução {RUN} (modelo em produção: {PRODUCAO}).",
            fontsize=9, color=SUAVE, va="top", style="italic")

    saida = PASTA / f"metricas_{h}_dias.png"
    fig.savefig(saida, facecolor=PAPEL)
    plt.close(fig)
    return saida


for h in (3, 7, 14):
    g = prev[prev["horizonte"] == h]
    tab = g.groupby("modelo").apply(metricas, include_groups=False).reset_index()
    naive = tab.set_index("modelo").loc["Naive"]
    tab["U"] = tab["RMSE"] / naive["RMSE"]
    tab["Ganho"] = (1 - tab["MAE"] / naive["MAE"]) * 100
    tab = tab.sort_values("MAE").reset_index(drop=True)
    n = int(g.groupby("modelo").size().iloc[0])
    print(desenhar(tab, h, n))
