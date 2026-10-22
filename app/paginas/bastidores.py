import json
from pathlib import Path

import pandas as pd
import plotly.graph_objects as go
import streamlit as st

import dados
import formato as f

st.title("Bastidores do MLOps")
st.caption("Como o pipeline roda, o que ele decidiu e quanto custou. Tudo lido das tabelas mlops do BigQuery.")

execs = dados.execucoes()
versoes = dados.versoes()
producao = dados.producao_atual()
ultima = execs.iloc[0] if not execs.empty else None

def descrever_versao(versao: str) -> str:
    """Nome legível da versão em produção: o modelo, quando é o mesmo em todas as séries."""
    if versao == "naive":
        return "Naive em tudo"
    linha = versoes[versoes["versao_id"] == versao]
    if linha.empty:
        return versao
    usados = json.loads(linha.iloc[0]["modelos_usados"] or "{}")
    return f"{next(iter(usados))} em tudo" if len(usados) == 1 else "Um modelo por série"


k1, k2, k3, k4 = st.columns(4)
k1.metric("Versão em produção", descrever_versao(producao),
          help=f"Versão {producao}. Antes da primeira promoção, o campeão é o Naive em todos os produtos.")
if ultima is not None:
    k2.metric("Última execução", f.data_hora_local(ultima["inicio"]), ultima["status"], delta_color="off")
k3.metric("Execuções registradas", len(execs))
k4.metric("Custo total estimado", f"US$ {execs['custo_usd'].sum():.2f}".replace(".", ","),
          help="Soma da view custo_execucoes, sem a cota gratuita do Cloud Run.")

imagem = Path(__file__).resolve().parent.parent / "assets" / "arquitetura.png"
if imagem.exists():
    st.image(str(imagem), width="stretch")
st.info(
    "**Treino semanal:** o agendador dispara a avaliação completa dos modelos toda terça-feira às 16:00.  \n"
    "**Inferência diária:** sempre que a `silver.ceasa_unificado` é regravada, um coletor de logs publica um "
    "aviso no tópico do Pub/Sub `ceasa-dados-atualizados`; o Eventarc chama um Workflow, que roda só a previsão "
    "com o modelo em produção. Se os dados não mudaram, o job encerra em cerca de 1 minuto."
)

# Decisões do champion–challenger
st.subheader("Decisões do champion–challenger")
st.caption(
    "A cada treino nasce uma versão candidata. Ela só vai para produção se errar pelo menos 1% menos que o "
    "campeão atual no holdout, as semanas que não foram usadas para escolher os modelos."
)
if versoes.empty:
    st.write("Nenhuma versão registrada ainda.")
else:
    v = versoes.copy()
    v["Data"] = v["criado_em"].map(f.data_hora_local)
    v["Ganho sobre o campeão"] = 1 - v["mae_holdout_candidata"] / v["mae_holdout_campeao"]
    v["Modelos na candidata"] = v["modelos_usados"].map(
        lambda s: ", ".join(f"{k} ({n})" for k, n in list(json.loads(s).items())[:4]) + "…" if s else "—"
    )
    st.dataframe(
        v[["Data", "decisao", "mae_holdout_candidata", "mae_holdout_campeao", "Ganho sobre o campeão", "motivo", "Modelos na candidata"]],
        hide_index=True, width="stretch",
        column_config={
            "decisao": "Decisão",
            "mae_holdout_candidata": st.column_config.NumberColumn("Erro da candidata", format="R$ %.3f"),
            "mae_holdout_campeao": st.column_config.NumberColumn("Erro do campeão", format="R$ %.3f"),
            "Ganho sobre o campeão": st.column_config.NumberColumn(format="percent"),
            "motivo": st.column_config.TextColumn("Motivo", width="large"),
        },
    )

# Execuções
st.subheader("Execuções")
if not execs.empty:
    e = execs.copy()
    e["Início"] = e["inicio"].map(f.data_hora_local)
    e["Duração (min)"] = (pd.to_datetime(e["fim"]) - pd.to_datetime(e["inicio"])).dt.total_seconds() / 60
    e["Disparada por"] = e["origem"].map(lambda o: "local" if o == "local" else "Cloud Run")
    st.dataframe(
        e[["Início", "tipo", "status", "experimento", "versao_codigo", "ultima_semana", "decisao", "Duração (min)", "custo_usd", "erro"]],
        hide_index=True, width="stretch",
        column_config={
            "tipo": st.column_config.TextColumn("Tipo", help="treino (semanal), inferencia (diária, Pub/Sub) ou verificacao"),
            "status": "Status",
            "experimento": st.column_config.TextColumn("Experimento", help="Execuções de teste não mexem na produção"),
            "versao_codigo": "Versão do código",
            "ultima_semana": st.column_config.DateColumn("Dados até", format="DD/MM/YYYY"),
            "decisao": "Decisão",
            "Duração (min)": st.column_config.NumberColumn(format="%.0f"),
            "custo_usd": st.column_config.NumberColumn("Custo (US$)", format="%.2f"),
            "erro": st.column_config.TextColumn("Erro", width="medium"),
        },
    )
    st.caption(
        "Status sem_dados_novos: o pipeline viu que os dados não mudaram e encerrou sem treinar. Até a v0.4 o "
        "pipeline previa o preço semanal só da CEASA-GO; a partir da v0.5, o preço diário de todas as CEASAs."
    )

# Tempo por modelo na última execução de treino
treino = dados.ultima_execucao()
if treino is not None:
    tempos = pd.Series(dados.tempos_da_execucao(treino)).sort_values()
    st.subheader("Tempo de cada modelo no último treino")
    fig = go.Figure(go.Bar(
        x=tempos.values / 60, y=tempos.index, orientation="h",
        marker_color=[f.cor(m) for m in tempos.index],
        text=[f"{v / 60:.1f} min" for v in tempos.values], textposition="outside",
        hovertemplate="%{y}: %{x:.1f} min<extra></extra>",
    ))
    fig.update_xaxes(ticksuffix=" min")
    f.layout_grafico(fig, altura=32 * len(tempos) + 80)
    fig.update_layout(hovermode="closest", showlegend=False)
    st.plotly_chart(fig, width="stretch")
