"""Abre cada página como o Streamlit faria, com o BigQuery trocado por respostas sintéticas."""
from pathlib import Path

import pandas as pd
import pytest
from streamlit.testing.v1 import AppTest

import bigquery_falso
import dados

PAGINAS = Path(__file__).resolve().parents[1] / "paginas"


@pytest.fixture(autouse=True)
def sem_bigquery(monkeypatch):
    monkeypatch.setattr(dados, "_consultar", bigquery_falso.consultar)

    def proibido():
        raise AssertionError("a página tentou acessar o BigQuery de verdade")

    monkeypatch.setattr(dados, "_cliente", proibido)


def abrir(pagina: str, **estado) -> AppTest:
    at = AppTest.from_file(str(PAGINAS / f"{pagina}.py"), default_timeout=60)
    for chave, valor in estado.items():
        at.session_state[chave] = valor
    at.run()
    assert not at.exception, [e.value for e in at.exception]
    return at


@pytest.mark.parametrize("pagina", ["previsoes", "validacao", "modelos", "bastidores"])
def test_pagina_abre_sem_erro(pagina):
    abrir(pagina)


def test_previsoes_mostra_os_cartoes_do_preco_atual_e_da_previsao():
    cartoes = " ".join(h.value for h in abrir("previsoes").html)
    assert "Preço do <em>Tomate longa vida</em>" in cartoes
    assert "cotação de 19/10/2026" in cartoes
    assert "do menor ao maior preço do boletim" in cartoes
    assert "Previsão para segunda, 26/10/2026 · 7 dias à frente" in cartoes
    assert "<strong>Chronos2</strong>, o modelo em produção" in cartoes
    assert "errou em média R$" in cartoes


def test_previsoes_mostra_os_destaques_do_historico():
    cartoes = " ".join(h.value for h in abrir("previsoes").html)
    assert "no trimestre" in cartoes and "pico R$" in cartoes and "mínima R$" in cartoes and "em 2 anos" in cartoes
    for horizonte in ("em 3 dias", "em 7 dias", "em 14 dias"):
        assert horizonte in cartoes


def test_previsoes_compara_a_ceasa_atrasada_com_as_outras_na_mesma_data():
    at = abrir("previsoes", ceasa_escolhida="MS", produto_escolhido="tomate_longa_vida")
    cartoes = " ".join(h.value for h in at.html)
    assert "Preço do <em>Tomate longa vida</em>" in cartoes and "cotação de 02/10/2026" in cartoes
    assert "mais barato em GO" in cartoes or "o menor preço entre 2 CEASAs" in cartoes


def test_previsoes_diz_que_veio_da_atualizacao_pelo_pubsub():
    legendas = " ".join(c.value for c in abrir("previsoes").caption)
    assert "atualização disparada pelo Pub/Sub" in legendas


def test_previsoes_mostra_a_verificacao_sem_dado_novo_no_fim_de_semana():
    legendas = " ".join(c.value for c in abrir("previsoes").caption)
    assert ("Última verificação: 24/10/2026 16:35, sem dado novo na silver (no fim de semana a coleta não roda)"
            in legendas)


def test_previsoes_avisa_quando_a_ultima_verificacao_falhou(monkeypatch):
    monkeypatch.setattr(bigquery_falso, "ULTIMA_VERIFICACAO", bigquery_falso.ULTIMA_VERIFICACAO.assign(status="falhou"))
    assert any("falhou" in aviso.value for aviso in abrir("previsoes").warning)


def test_previsoes_nao_repete_a_verificacao_que_gerou_as_previsoes(monkeypatch):
    # A inferência que gerou as previsões começou antes de gravá-las: a legenda principal já basta.
    anterior = bigquery_falso.ULTIMA_VERIFICACAO.assign(inicio=pd.Timestamp("2026-10-21 14:55", tz="UTC"),
                                                         status="sucesso")
    monkeypatch.setattr(bigquery_falso, "ULTIMA_VERIFICACAO", anterior)
    legendas = " ".join(c.value for c in abrir("previsoes").caption)
    assert "Última verificação" not in legendas


def test_app_principal_abre_e_o_botao_atualizar_funciona():
    at = AppTest.from_file(str(PAGINAS.parent / "app.py"), default_timeout=60)
    at.run()
    assert not at.exception, [e.value for e in at.exception]
    at.button[0].click().run()
    assert not at.exception, [e.value for e in at.exception]


def test_previsoes_avisa_quando_a_ceasa_esta_atrasada():
    at = abrir("previsoes", ceasa_escolhida="MS", produto_escolhido="tomate_longa_vida")
    assert any("vão só até 02/10/2026" in aviso.value for aviso in at.warning)


def test_validacao_funciona_para_a_ceasa_atrasada():
    abrir("validacao", ceasa_escolhida="MS", produto_escolhido="chuchu")


def test_comparacao_mostra_o_mapa_por_ceasa():
    assert len(abrir("modelos").get("plotly_chart")) == 3


def test_bastidores_mostra_o_modelo_em_producao():
    metricas = {m.label: m.value for m in abrir("bastidores").metric}
    assert metricas["Versão em produção"] == "Chronos2 em tudo"
