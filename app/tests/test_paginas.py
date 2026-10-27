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


def test_previsoes_mostra_o_modelo_em_producao_e_a_data_escolhida():
    metricas = {m.label: m.value for m in abrir("previsoes").metric}
    assert metricas["Modelo em produção"] == "Chronos2"
    assert any(rotulo.startswith("Previsão oficial para") for rotulo in metricas)


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
