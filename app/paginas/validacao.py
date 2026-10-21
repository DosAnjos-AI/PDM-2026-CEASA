import numpy as np
import pandas as pd
import plotly.graph_objects as go
import streamlit as st

import componentes
import dados
import formato as f

st.title("O modelo acertou?")

execucao = dados.ultima_execucao()
if execucao is None:
    st.info("Ainda não há execuções do pipeline com avaliação de modelos.")
    st.stop()

cfg = dados.config_da_execucao(execucao)
val = cfg["validacao"]
horizontes = val["horizontes"]
cortes = dados.cortes_cv(execucao["run_id"])
inicio_holdout = pd.Timestamp(cortes[-val["janelas_holdout"]])
passo = f.rotulo_horizonte(val["passo"], cfg)
rotulos = [f.rotulo_horizonte(h, cfg) for h in horizontes]

st.markdown(
    "Para saber se um modelo é bom, **voltamos no tempo e deixamos ele prever o passado**, usando só os dados "
    "que existiam em cada momento. Isso se chama **walk-forward**: a cada "
    f"{passo} o modelo treina com o histórico até ali e prevê {', '.join(rotulos[:-1])} e {rotulos[-1]} à frente. "
    "Depois comparamos com o preço que realmente aconteceu."
)

uid = componentes.escolher_serie(sorted(dados.series_cv(execucao["run_id"])), "validacao")
cv = dados.previsoes_cv(execucao["run_id"], uid)
if cv.empty:
    st.info("Este produto não foi avaliado na última execução.")
    st.stop()

modelos_disp = sorted(cv["modelo"].unique())
prev = dados.previsoes_atuais()
oficial = prev.loc[(prev["unique_id"] == uid) & prev["e_campeao"], "modelo"]
padrao = list(dict.fromkeys([*oficial.head(1), "Naive"]))   # modelo em produção + a régua
escolhidos = st.multiselect("Modelos", modelos_disp, default=[m for m in padrao if m in modelos_disp],
                            max_selections=4)

hist = dados.historico(uid, cfg)
fim = cv["ds"].max()
hist = hist[(hist["ds"] >= pd.Timestamp(cortes[0]) - pd.Timedelta(days=30)) & (hist["ds"] <= fim)]
preco_no_corte = hist.set_index("ds")["y"]

fig = go.Figure()
fig.add_vrect(x0=inicio_holdout, x1=fim + pd.Timedelta(days=3), fillcolor=f.HOLDOUT, line_width=0)
fig.add_annotation(x=pd.Timestamp(cortes[0]), y=1, yref="paper", text="SELEÇÃO: usada para escolher os modelos",
                   showarrow=False, xanchor="left", yanchor="bottom", font=dict(size=11, color=f.SUAVE))
fig.add_annotation(x=inicio_holdout, y=1, yref="paper", text="HOLDOUT: só confere a escolha",
                   showarrow=False, xanchor="left", yanchor="bottom", font=dict(size=11, color=f.TERRA))
fig.add_scatter(x=hist["ds"], y=hist["y"], name="Preço real", mode="lines", line=dict(color=f.REAL, width=2))

for modelo in escolhidos:
    g = cv[cv["modelo"] == modelo]
    primeira = True
    for corte, trecho in g.groupby("cutoff"):
        corte = pd.Timestamp(corte)
        fig.add_scatter(
            x=[corte, *trecho["ds"]], y=[preco_no_corte.get(corte, np.nan), *trecho["yhat"]],
            name=modelo, legendgroup=modelo, showlegend=primeira, mode="lines+markers",
            line=dict(color=f.cor(modelo), width=2, dash="dot"), marker=dict(size=5),
        )
        primeira = False
fig.update_yaxes(tickprefix="R$ ", separatethousands=True)
f.layout_grafico(fig, altura=480)
st.plotly_chart(fig, width="stretch")

n_cortes_serie = cv["cutoff"].nunique()
st.caption(
    f"Cada trecho pontilhado sai do preço real do dia do corte e liga as previsões de {', '.join(rotulos)} feitas "
    f"naquele dia. São {len(cortes)} cortes: os {len(cortes) - val['janelas_holdout']} primeiros formam a seleção e "
    f"os {val['janelas_holdout']} últimos (área sombreada) formam o holdout, que não é usado para escolher modelos."
    + (f" Esta série tem {n_cortes_serie} cortes porque os dados dela terminam antes." if n_cortes_serie < len(cortes) else "")
)

# Erro médio deste produto, por modelo e período
cv["erro"] = (cv["y"] - cv["yhat"]).abs()
cv["periodo"] = np.where(cv["cutoff"] >= inicio_holdout, "Holdout", "Seleção")
tab = cv.pivot_table(index="modelo", columns="periodo", values="erro", aggfunc="mean")
tab["Geral"] = cv.groupby("modelo")["erro"].mean()
for coluna in ["Seleção", "Holdout"]:
    if coluna not in tab:
        tab[coluna] = np.nan
tab = tab[["Geral", "Seleção", "Holdout"]].sort_values("Geral")
if "Naive" in tab.index:
    tab["Ganho sobre o Naive (geral)"] = 1 - tab["Geral"] / tab.loc["Naive", "Geral"]

st.subheader(f"Erro médio em {f.nome_serie(uid)}")
st.dataframe(
    tab, width="stretch",
    column_config={
        "Geral": st.column_config.NumberColumn("Erro médio geral", format="R$ %.2f"),
        "Seleção": st.column_config.NumberColumn("Erro na seleção", format="R$ %.2f"),
        "Holdout": st.column_config.NumberColumn("Erro no holdout", format="R$ %.2f"),
        "Ganho sobre o Naive (geral)": st.column_config.NumberColumn(format="percent"),
    },
)
st.caption(
    f"Erro médio = MAE, a diferença média entre o previsto e o real, em {f.unidade(cfg)}. Este quadro vale só "
    "para o produto escolhido; o resultado geral está em Comparação de modelos."
)
