import pandas as pd
import pytest

from auxiliares import PrevisorFalso
from conftest import FIM, FIM_MS
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


HOJE = (FIM + pd.Timedelta(days=1)).date()   # GO com dado de ontem; MS parada desde FIM_MS


def test_serie_atrasada_publica_os_14_dias_a_partir_de_hoje(selecionadas, modelos_falsos):
    out = previsao.gerar(selecionadas, None, modelos_falsos, {}, {}, HOJE)
    go = out[(out["unique_id"] == "GO__tomate") & (out["modelo"] == "Naive")]
    assert sorted(go["horizonte"]) == list(range(1, 15))
    ms = out[(out["unique_id"] == "MS__tomate") & (out["modelo"] == "Naive")]
    assert sorted(ms["ds"]) == list(pd.date_range(HOJE, periods=14))
    atraso = (pd.Timestamp(HOJE) - FIM_MS).days                        # horizonte conta do último dado
    assert sorted(ms["horizonte"]) == list(range(atraso, atraso + 14))
    assert (ms["ultima_semana"] == FIM_MS).all()
    assert out.groupby(["unique_id", "ds"])["e_campeao"].sum().eq(1).all()


def test_atualizadas_e_atrasadas_sao_previstas_em_chamadas_separadas(selecionadas, cfg, monkeypatch):
    chamadas = []

    class Registrador(PrevisorFalso):
        def prever(self, treino, ids, h, clima):
            chamadas.append((sorted(ids), h))
            return super().prever(treino, ids, h, clima)

    monkeypatch.setattr(previsao.modelos, "criar", lambda nome, cfg, params=None: Registrador(nome))
    previsao.gerar(selecionadas, None, cfg, {}, {}, HOJE)
    # As atualizadas continuam com 14 dias, como sem atraso; a MS prevê também os dias até hoje.
    atraso = (pd.Timestamp(HOJE) - FIM_MS).days
    assert sorted(chamadas) == [(["GO__chuchu", "GO__tomate"], 14), (["MS__tomate"], 14 + atraso - 1)]


def test_serie_atrasada_demais_fica_sem_previsao(selecionadas, modelos_falsos):
    modelos_falsos["inferencia"] = {"atraso_maximo": 10}
    out = previsao.gerar(selecionadas, None, modelos_falsos, {}, {}, HOJE)
    assert set(out["unique_id"]) == {"GO__tomate", "GO__chuchu"}


def test_modelo_direto_fica_sem_as_series_atrasadas(selecionadas, modelos_falsos, monkeypatch):
    modelos_falsos["modelos"]["Direto"] = {"ativo": True}

    def criar(nome, cfg, params=None):
        previsor = PrevisorFalso(nome)
        previsor.direta = nome == "Direto"      # só prevê os horizontes treinados (3, 7 e 14)
        return previsor

    monkeypatch.setattr(previsao.modelos, "criar", criar)
    out = previsao.gerar(selecionadas, None, modelos_falsos, {}, {}, HOJE)
    assert set(out.loc[out["modelo"] == "Direto", "unique_id"]) == {"GO__tomate", "GO__chuchu"}
    assert "MS__tomate" in set(out.loc[out["modelo"] == "Naive", "unique_id"])


def test_publica_so_a_lista_da_inferencia_mais_o_naive_e_o_campeao(selecionadas, modelos_falsos):
    modelos_falsos["modelos"]["ARIMA"] = {"ativo": True}
    modelos_falsos["modelos"]["Theta"] = {"ativo": True}
    modelos_falsos["inferencia"] = {"modelos": ["Chronos2"]}
    out = previsao.gerar(selecionadas, None, modelos_falsos, {"GO__tomate": "ARIMA"}, {})
    assert set(out["modelo"]) == {"Naive", "Chronos2", "ARIMA"}          # Theta só entra no walk-forward
    campeoes = out[out["e_campeao"]].groupby("unique_id")["modelo"].first().to_dict()
    assert campeoes == {"GO__tomate": "ARIMA", "GO__chuchu": "Naive", "MS__tomate": "Naive"}


def test_sem_secao_de_inferencia_publica_todos_os_ativos(selecionadas, modelos_falsos):
    out = previsao.gerar(selecionadas, None, modelos_falsos, {}, {})
    assert set(out["modelo"]) == {"Naive", "Chronos2"}


def test_inferencia_com_modelo_desativado_falha(selecionadas, modelos_falsos):
    modelos_falsos["inferencia"] = {"modelos": ["Chronos2", "Desligado"]}
    with pytest.raises(ValueError, match="Desligado"):
        previsao.gerar(selecionadas, None, modelos_falsos, {}, {})


def test_exige_o_naive_ativo(selecionadas, modelos_falsos):
    modelos_falsos["modelos"]["Naive"]["ativo"] = False
    with pytest.raises(ValueError, match="Naive"):
        previsao.gerar(selecionadas, None, modelos_falsos, {}, {})
