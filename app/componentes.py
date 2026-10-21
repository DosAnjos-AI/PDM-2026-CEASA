"""Seletores compartilhados entre as páginas."""
import streamlit as st

import formato as f


def escolher_serie(ids: list[str], pagina: str) -> str:
    """Escolhe CEASA + produto entre as séries `ids` e lembra a escolha entre as páginas."""
    partes = {u: f.dividir(u) for u in ids}

    if all(classe is not None for _, _, classe in partes.values()):
        # Fonte semanal antiga: só CEASA-GO, séries por produto e classe.
        opcoes = sorted(ids, key=f.nome_serie)
        padrao = st.session_state.get("serie_escolhida", "tomate_longa_vida__c1")
        uid = st.selectbox("Produto", opcoes, index=opcoes.index(padrao) if padrao in opcoes else 0,
                           format_func=f.nome_serie, key=f"{pagina}_serie")
        st.session_state["serie_escolhida"] = uid
        return uid

    ceasas = [c for c in f.CEASAS if any(p[0] == c for p in partes.values())]
    c1, c2 = st.columns([2, 3], vertical_alignment="bottom")
    padrao_ceasa = st.session_state.get("ceasa_escolhida", "GO")
    ceasa = c2.segmented_control(
        "CEASA", ceasas, default=padrao_ceasa if padrao_ceasa in ceasas else ceasas[0],
        format_func=lambda c: c, help=" · ".join(f.CEASAS[c] for c in ceasas), key=f"{pagina}_ceasa",
    ) or padrao_ceasa
    produtos = sorted({p for c, p, _ in partes.values() if c == ceasa}, key=f.nome_produto)
    padrao_produto = st.session_state.get("produto_escolhido", "tomate_longa_vida")
    produto = c1.selectbox(
        "Produto", produtos, index=produtos.index(padrao_produto) if padrao_produto in produtos else 0,
        format_func=f.nome_produto, key=f"{pagina}_produto",
    )
    st.session_state["ceasa_escolhida"], st.session_state["produto_escolhido"] = ceasa, produto
    return f"{ceasa}__{produto}"
