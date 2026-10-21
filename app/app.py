"""Aplicação de visualização do pipeline de previsão de preços das CEASAs.

Rodar localmente:  streamlit run app.py
"""
import streamlit as st

st.set_page_config(page_title="Preços CEASA", page_icon=":material/eco:", layout="wide")

paginas = st.navigation([
    st.Page("paginas/previsoes.py", title="Previsões", icon=":material/trending_up:", default=True),
    st.Page("paginas/validacao.py", title="O modelo acertou?", icon=":material/fact_check:"),
    st.Page("paginas/modelos.py", title="Comparação de modelos", icon=":material/leaderboard:"),
    st.Page("paginas/bastidores.py", title="Bastidores do MLOps", icon=":material/settings:"),
])

with st.sidebar:
    st.caption(
        "Previsão do preço por kg de hortifrútis nas CEASAs de GO, MG, ES, SC e MS, de 3 a 14 dias à frente. "
        "Os dados vêm do BigQuery e são atualizados automaticamente toda terça-feira pelo pipeline de "
        "MLOps no Cloud Run."
    )

paginas.run()
