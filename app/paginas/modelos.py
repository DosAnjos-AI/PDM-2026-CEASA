import pandas as pd
import plotly.graph_objects as go
import streamlit as st

import dados
import formato as f

st.title("Comparação de modelos")

execucao = dados.ultima_execucao()
if execucao is None:
    st.info("Ainda não há execuções do pipeline com avaliação de modelos.")
    st.stop()

cfg = dados.config_da_execucao(execucao)
met = dados.metricas(execucao["run_id"])
tempos = dados.tempos_da_execucao(execucao)
n_cortes = len(dados.cortes_cv(execucao["run_id"]))

st.caption(
    f"Execução de {f.data_hora_local(execucao['inicio'])} · {int(execucao['series_usadas'])} séries · "
    f"todos os modelos testados nos mesmos {n_cortes} cortes do walk-forward"
)

rotulos = {"todas": "Todos os cortes", "selecao": "Seleção", "holdout": "Holdout"}
periodo = st.segmented_control(
    "Período", list(rotulos), default="todas", format_func=rotulos.get,
    help="Seleção: cortes usados para escolher modelos. Holdout: cortes reservados para a prova final.",
) or "todas"
m = met[met["periodo"] == periodo]
geral = m[m["horizonte"] == 0].sort_values("ganho_vs_naive")
horizontes = sorted(h for h in m["horizonte"].unique() if h > 0)

# Resumo automático
melhor = geral.iloc[-1]
mais_curto = m[(m["horizonte"] == horizontes[0]) & (m["modelo"] != "Naive")]
a, b = st.columns(2)
a.metric("Melhor modelo no período", melhor["modelo"], f.pct(melhor["ganho_vs_naive"]) + " contra o Naive")
b.metric(
    "Modelos que ganham do Naive",
    f"{int((geral['ganho_vs_naive'] > 0).sum())} de {len(geral) - 1}",
    f"nenhum ganha para {f.rotulo_horizonte(horizontes[0], cfg)} à frente" if (mais_curto["ganho_vs_naive"] <= 0).all() else None,
    delta_color="off",
)

# Ganho geral sobre o Naive
fig = go.Figure(go.Bar(
    x=geral["ganho_vs_naive"] * 100, y=geral["modelo"], orientation="h",
    marker_color=[f.FOLHA if v > 0 else (f.SUAVE if v == 0 else f.RUIM) for v in geral["ganho_vs_naive"]],
    text=[f.pct(v) for v in geral["ganho_vs_naive"]], textposition="outside",
    hovertemplate="%{y}: %{x:.1f}%<extra></extra>",
))
fig.update_xaxes(ticksuffix="%", title="quanto o modelo erra a menos que o Naive (positivo = melhor)")
f.layout_grafico(fig, altura=40 * len(geral) + 80)
fig.update_layout(hovermode="closest", showlegend=False)
st.subheader("Quem ganha do Naive?")
st.plotly_chart(fig, width="stretch")
st.caption("O Naive repete o último preço. Como preço de hortifrúti muda pouco de um dia para outro, ele é difícil de vencer.")

# Ganho por horizonte
st.subheader("Depende de quanto tempo à frente")
por_h = m[m["horizonte"] > 0]
candidatos = [x for x in geral.sort_values("ganho_vs_naive", ascending=False)["modelo"] if x != "Naive"]
escolhidos = st.multiselect("Modelos", candidatos, default=candidatos[:4])
fig2 = go.Figure()
fig2.add_hline(y=0, line=dict(color=f.SUAVE, dash="dash"), annotation_text="Naive", annotation_position="right")
for modelo in escolhidos:
    g = por_h[por_h["modelo"] == modelo].sort_values("horizonte")
    fig2.add_scatter(x=[f.rotulo_horizonte(h, cfg) for h in g["horizonte"]], y=g["ganho_vs_naive"] * 100,
                     name=modelo, mode="lines+markers", line=dict(color=f.cor(modelo), width=2.5), marker=dict(size=9))
fig2.update_yaxes(ticksuffix="%")
f.layout_grafico(fig2, altura=400)
fig2.update_layout(hovermode="closest")
st.plotly_chart(fig2, width="stretch")
st.caption("Quanto mais perto, mais difícil ganhar de repetir o último preço; os modelos costumam ganhar vantagem em horizontes mais longos.")

# Ganho por CEASA (só na fonte com várias CEASAs)
ms = dados.metricas_serie(execucao["run_id"])
if ms["ceasa"].nunique() > 1:
    st.subheader("Onde cada modelo ganha do Naive")
    soma = ms.groupby(["ceasa", "modelo"])["mae"].sum().unstack()
    ganho = (1 - soma.div(soma["Naive"], axis=0)).drop(columns="Naive").T
    ganho = ganho.loc[ganho.mean(axis=1).sort_values().index, [c for c in f.CEASAS if c in ganho.columns]]
    fig3 = go.Figure(go.Heatmap(
        z=ganho.values * 100, x=list(ganho.columns), y=list(ganho.index),
        colorscale=[[0, f.RUIM], [0.5, "#f4f4f0"], [1, f.FOLHA]], zmid=0, zmin=-15, zmax=15,
        text=[[f.pct(v) for v in linha] for linha in ganho.values], texttemplate="%{text}",
        hovertemplate="%{y} em %{x}: %{z:.1f}%<extra></extra>", colorbar=dict(ticksuffix="%"),
    ))
    f.layout_grafico(fig3, altura=36 * len(ganho) + 80)
    fig3.update_layout(hovermode="closest")
    st.plotly_chart(fig3, width="stretch")
    st.caption(
        "Ganho de cada modelo sobre o Naive em cada CEASA, somando os erros de todos os cortes e horizontes. "
        "Em CEASAs onde a cotação quase não muda (SC e MS), repetir o último preço é muito difícil de vencer."
    )

# Tabela completa
st.subheader("Todos os números")
tabela = geral.sort_values("mae")[["modelo", "mae", "rmse", "wape", "r2", "ganho_vs_naive"]].copy()
tabela["descricao"] = tabela["modelo"].map(f.DESCRICAO_MODELO)
tabela["tempo"] = tabela["modelo"].map(tempos)
st.dataframe(
    tabela[["modelo", "descricao", "mae", "rmse", "wape", "r2", "ganho_vs_naive", "tempo"]],
    hide_index=True, width="stretch",
    column_config={
        "modelo": "Modelo",
        "descricao": "O que é",
        "mae": st.column_config.NumberColumn("Erro médio (MAE)", format="R$ %.2f"),
        "rmse": st.column_config.NumberColumn("RMSE", format="%.2f", help="Pesa mais os erros grandes"),
        "wape": st.column_config.NumberColumn("WAPE", format="percent", help="Erro total dividido pelo valor total"),
        "r2": st.column_config.NumberColumn("R²", format="%.3f"),
        "ganho_vs_naive": st.column_config.NumberColumn("Ganho sobre o Naive", format="percent"),
        "tempo": st.column_config.NumberColumn("Tempo (s)", format="%.0f", help="Tempo do walk-forward na execução"),
    },
)
