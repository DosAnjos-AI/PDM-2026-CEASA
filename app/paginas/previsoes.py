import pandas as pd
import plotly.graph_objects as go
import streamlit as st

import componentes
import dados
import formato as f

st.title("Previsões de preço")

execucao = dados.ultima_execucao()
prev = dados.previsoes_atuais()
if execucao is None or prev.empty:
    st.info("Ainda não há previsões publicadas. Elas aparecem depois da primeira execução do pipeline.")
    st.stop()

cfg = dados.config_da_execucao(execucao)
h_max = int(prev["horizonte"].max())
st.caption(
    f"Preço comum em {f.unidade(cfg)} · previsões para até {f.rotulo_horizonte(h_max, cfg)} à frente · "
    f"geradas em {f.data_hora_local(prev['gerado_em'].max())}"
)

uid = componentes.escolher_serie(sorted(prev["unique_id"].unique()), "previsoes")
ceasa, produto, _ = f.dividir(uid)
p = prev[prev["unique_id"] == uid].sort_values("ds")
ultima = pd.Timestamp(p["ultima_semana"].iloc[0])
oficial = p[p["e_campeao"]].sort_values("ds")
outros = p[~p["e_campeao"]]
modelo_oficial = oficial["modelo"].iloc[0]

hist = dados.historico(uid, cfg)
base = hist.loc[hist["ds"] == ultima, "y"]
ultimo_preco = float(base.iloc[0]) if not base.empty else float("nan")

if ultima < prev["ultima_semana"].max():
    st.warning(
        f"Os dados da {f.CEASAS.get(ceasa, ceasa)} vão só até {f.data(ultima)}, então as previsões partem dessa "
        "data. Elas se atualizam quando a CEASA voltar a ser carregada na silver."
    )

# Data da previsão: qualquer data prevista pelo modelo oficial (até h_max à frente do último dado)
datas = list(oficial["ds"])
horizonte_da_data = dict(zip(oficial["ds"], oficial["horizonte"]))
padrao = next((d for d in datas if horizonte_da_data[d] == 7), datas[-1])
data_alvo = st.select_slider(
    "Data da previsão", options=datas, value=padrao,
    format_func=lambda d: f"{d:%d/%m} (+{f.rotulo_horizonte(horizonte_da_data[d], cfg)})",
)
h_alvo = horizonte_da_data[data_alvo]
previsto = float(oficial.loc[oficial["ds"] == data_alvo, "yhat"].iloc[0])
real = hist.loc[hist["ds"] == data_alvo, "y"]

k1, k2, k3 = st.columns(3)
k1.metric(f"Preço em {f.data(ultima)} (último dado)", f.brl(ultimo_preco))
k2.metric(
    f"Previsão oficial para {f.data(data_alvo)}", f.brl(previsto),
    delta=f"{f.pct(previsto / ultimo_preco - 1)} em relação ao último dado" if ultimo_preco else None,
    delta_color="off",
)
k3.metric("Modelo em produção", modelo_oficial, help=f.DESCRICAO_MODELO.get(modelo_oficial))
if not real.empty:
    erro = previsto - float(real.iloc[0])
    st.success(
        f"Essa data já passou: o preço real em {f.data(data_alvo)} foi {f.brl(float(real.iloc[0]))}. "
        f"A previsão errou por {f.brl(abs(erro))} ({'acima' if erro > 0 else 'abaixo'} do real)."
    )

disponiveis = sorted(outros["modelo"].unique())
sugeridos = [m for m in ["Naive", "Chronos2_clima", "ARIMA", "Chronos2"] if m in disponiveis][:3]
c1, c2 = st.columns([3, 2], vertical_alignment="bottom")
comparar = c1.multiselect(
    "Comparar com outros modelos", disponiveis, default=sugeridos,
    format_func=lambda m: f"{m} ({f.DESCRICAO_MODELO.get(m, '')})",
)
janelas = {"3 meses": 91, "6 meses": 182, "1 ano": 365, "2 anos": 730, "Tudo": None}
opcoes_janela = ["3 meses", "6 meses", "1 ano", "Tudo"] if f.diario(cfg) else ["6 meses", "1 ano", "2 anos", "Tudo"]
janela = c2.segmented_control("Histórico no gráfico", opcoes_janela, default=opcoes_janela[1]) or opcoes_janela[1]

# Gráfico: histórico real + previsão oficial + outros modelos, com a data escolhida destacada
dias = janelas[janela]
h = hist if dias is None else hist[hist["ds"] > ultima - pd.Timedelta(days=dias)]
fig = go.Figure()
fig.add_scatter(x=h["ds"], y=h["y"], name="Preço real", mode="lines", line=dict(color=f.REAL, width=2))
for modelo in comparar:
    g = outros[outros["modelo"] == modelo]
    fig.add_scatter(
        x=[ultima, *g["ds"]], y=[ultimo_preco, *g["yhat"]], name=modelo, mode="lines+markers",
        line=dict(color=f.cor(modelo), width=1.6, dash="dot"), marker=dict(size=5), opacity=0.85,
    )
fig.add_scatter(
    x=[ultima, *oficial["ds"]], y=[ultimo_preco, *oficial["yhat"]], name=f"Previsão oficial ({modelo_oficial})",
    mode="lines+markers", line=dict(color=f.FOLHA, width=3, dash="dash"), marker=dict(size=6),
)
fig.add_scatter(
    x=[data_alvo], y=[previsto], name=f"Data escolhida ({f.data(data_alvo)})", mode="markers",
    marker=dict(size=16, color=f.FOLHA, line=dict(color="white", width=2), symbol="diamond"),
)
for x, texto, cor in [(ultima, "último dado", f.SUAVE), (data_alvo, "data escolhida", f.FOLHA)]:
    fig.add_shape(type="line", x0=x, x1=x, y0=0, y1=1, yref="paper", line=dict(color=cor, width=1, dash="dot"))
    fig.add_annotation(x=x, y=1, yref="paper", text=texto, showarrow=False, xanchor="right", yanchor="bottom",
                       font=dict(size=11, color=cor))
fig.update_yaxes(tickprefix="R$ ", separatethousands=True)
f.layout_grafico(fig, altura=460)
st.plotly_chart(fig, width="stretch")
st.caption(
    f"Gráfico de {f.nome_produto(produto)} na {f.CEASAS.get(ceasa, ceasa)}. Linha cheia: preço real. Tracejado verde: "
    "previsão oficial, feita pelo modelo em produção; o losango marca a data escolhida. Pontilhadas: o que os "
    "outros modelos preveem."
)

# Tabela dos próximos dias
tabela = p.pivot(index=["horizonte", "ds"], columns="modelo", values="yhat")
colunas = [modelo_oficial, *[m for m in comparar if m != modelo_oficial]]
tabela = tabela[colunas].rename(columns={modelo_oficial: f"{modelo_oficial} (oficial)"})
tabela.index = [
    f"{f.data(ds)} (+{f.rotulo_horizonte(hz, cfg)})" + ("  ◀ escolhida" if ds == data_alvo else "")
    for hz, ds in tabela.index
]
st.subheader("Previsão dia a dia" if f.diario(cfg) else "Próximas semanas")
st.dataframe(tabela.map(f.brl), width="stretch")
st.caption("— = o modelo não prevê essa data (os LightGBM diretos só preveem 3, 7 e 14 dias à frente).")

# Mesmo produto em todas as CEASAs (preço por kg é comparável)
if cfg["fonte"]["tipo"] == "silver_unificado":
    st.subheader(f"{f.nome_produto(produto)} nas outras CEASAs")
    todas = dados.produto_em_todas_as_ceasas(produto, (ultima - pd.Timedelta(days=182)).date(), cfg)
    prev_produto = prev[(prev["produto"] == produto) & prev["e_campeao"]]
    fig2 = go.Figure()
    for c in [c for c in f.CEASAS if c in set(todas["ceasa"])]:
        g = todas[todas["ceasa"] == c]
        fig2.add_scatter(x=g["ds"], y=g["y"], name=c, mode="lines",
                         line=dict(color=f.CORES_CEASA[c], width=2.6 if c == ceasa else 1.4), legendgroup=c)
        pc = prev_produto[prev_produto["ceasa"] == c].sort_values("ds")
        if not pc.empty and not g.empty:
            fig2.add_scatter(x=[g["ds"].iloc[-1], *pc["ds"]], y=[g["y"].iloc[-1], *pc["yhat"]], name=f"{c} previsto",
                             mode="lines", line=dict(color=f.CORES_CEASA[c], width=1.4, dash="dash"),
                             legendgroup=c, showlegend=False)
    fig2.update_yaxes(tickprefix="R$ ", title="R$/kg")
    f.layout_grafico(fig2, altura=380)
    st.plotly_chart(fig2, width="stretch")
    st.caption("Preço por kg nos últimos 6 meses em cada CEASA; o tracejado é a previsão oficial de cada uma.")

# Maiores variações previstas entre todas as séries, no mesmo horizonte da data escolhida
st.subheader(f"Maiores variações previstas em {f.rotulo_horizonte(h_alvo, cfg)}")
opcoes_rank = ["Oficial", *[m for m in sugeridos if m != modelo_oficial]]
# Com o Naive em produção a previsão oficial é sempre "sem variação"; abre no melhor modelo alternativo.
padrao_rank = opcoes_rank[1] if modelo_oficial == "Naive" and len(opcoes_rank) > 1 else "Oficial"
modelo_rank = st.segmented_control("Segundo o modelo", opcoes_rank, default=padrao_rank) or "Oficial"

alvo = prev[prev["horizonte"] == h_alvo]
alvo = alvo[alvo["e_campeao"]] if modelo_rank == "Oficial" else alvo[alvo["modelo"] == modelo_rank]
var = alvo.merge(dados.ultimos_precos(prev, cfg), on="unique_id")
var["variacao"] = var["yhat"] / var["y"] - 1
var["Produto"] = var["produto"].map(f.nome_produto)
var = var.rename(columns={"ceasa": "CEASA", "y": "Preço atual", "yhat": "Previsto"})
var = var[["Produto", "CEASA", "Preço atual", "Previsto", "variacao"]]

if var.empty:
    st.info(f"O modelo {modelo_rank} não prevê {f.rotulo_horizonte(h_alvo, cfg)} à frente. Escolha outra data ou outro modelo.")
elif var["variacao"].abs().max() < 1e-9:
    st.info(
        f"O modelo {modelo_rank if modelo_rank != 'Oficial' else modelo_oficial} repete o último preço: ele não "
        "prevê variações. Escolha outro modelo acima para ver para onde os preços estão indo."
    )
else:
    col_alta, col_baixa = st.columns(2)
    config = {
        "Preço atual": st.column_config.NumberColumn(format="R$ %.2f"),
        "Previsto": st.column_config.NumberColumn(format="R$ %.2f"),
        "variacao": st.column_config.NumberColumn("Variação", format="percent"),
    }
    col_alta.markdown("**Maiores altas**")
    col_alta.dataframe(var.nlargest(8, "variacao"), hide_index=True, column_config=config, width="stretch")
    col_baixa.markdown("**Maiores quedas**")
    col_baixa.dataframe(var.nsmallest(8, "variacao"), hide_index=True, column_config=config, width="stretch")
