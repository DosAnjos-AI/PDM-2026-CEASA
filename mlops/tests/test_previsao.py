import pandas as pd
import pytest

from auxiliares import PrevisorFalso
from conftest import FIM_MS
from pipeline import previsao


@pytest.fixture
def modelos_falsos(cfg, monkeypatch):
    cfg["modelos"] = {"Naive": {"ativo": True}, "Chronos2": {"ativo": True}, "Desligado": {"ativo": False}}
    monkeypatch.setattr(previsao.modelos, "criar", lambda nome, cfg, params=None: PrevisorFalso(nome, incremento=0.1))
    return cfg


def test_um_unico_campeao_por_serie_e_data(selecionadas, modelos_falsos):
    atribuicao = {"GO__tomate": "Chronos2", "MS__tomate": "Desligado"}   # Desligado cai no Naive
    out = previsao.gerar(selecionadas, None, modelos_falsos, atribuicao, {})
    assert out.groupby(["unique_id", "ds"])["e_campeao"].sum().eq(1).all()
    campeoes = out[out["e_campeao"]].groupby("unique_id")["modelo"].first().to_dict()
    assert campeoes == {"GO__tomate": "Chronos2", "GO__chuchu": "Naive", "MS__tomate": "Naive"}


def test_publica_os_14_dias_a_partir_da_ultima_data_de_cada_serie(selecionadas, modelos_falsos):
    out = previsao.gerar(selecionadas, None, modelos_falsos, {}, {})
    completos = out.groupby(["unique_id", "modelo"])["horizonte"].apply(lambda h: sorted(h) == list(range(1, 15)))
    assert completos.all()
    ms = out[out["unique_id"] == "MS__tomate"]
    assert (ms["ultima_semana"] == FIM_MS).all()
    assert ms["ds"].min() == FIM_MS + pd.Timedelta(days=1)


def test_exige_o_naive_ativo(selecionadas, modelos_falsos):
    modelos_falsos["modelos"]["Naive"]["ativo"] = False
    with pytest.raises(ValueError, match="Naive"):
        previsao.gerar(selecionadas, None, modelos_falsos, {}, {})
