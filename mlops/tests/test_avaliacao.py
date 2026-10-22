import numpy as np
import pandas as pd

from auxiliares import PrevisorFalso
from conftest import FIM_MS, serie
from pipeline import avaliacao


def test_cortes_diarios_caem_todos_no_mesmo_dia_util(selecionadas, cfg):
    cortes = avaliacao.cortes(selecionadas, cfg)
    assert len(cortes) == 4
    assert cortes[-1] == pd.Timestamp("2026-10-05")              # 19/10 - 14 dias
    assert {c.dayofweek for c in cortes} == {0}                   # todos na segunda
    assert set(np.diff(cortes)) == {pd.Timedelta(days=28)}


def test_corte_que_cairia_no_fim_de_semana_volta_para_sexta(cfg):
    # Último dado num domingo: 14 dias antes também é domingo, que na silver é interpolado.
    df = serie("GO__tomate", "2025-01-01", "2026-10-18", 1)
    assert avaliacao.cortes(df, cfg)[-1] == pd.Timestamp("2026-10-02")


def test_cortes_semanais(cfg):
    cfg["fonte"]["frequencia"] = "W-MON"
    cfg["validacao"].update(horizontes=[1, 2, 3, 4], passo=4, janelas=3)
    df = pd.DataFrame({"unique_id": "GO__tomate", "ds": pd.date_range("2024-01-01", "2026-10-12", freq="W-MON"), "y": 1.0})
    assert avaliacao.cortes(df, cfg) == [pd.Timestamp(d) for d in ("2026-07-20", "2026-08-17", "2026-09-14")]


def test_avaliar_so_usa_dados_ate_o_corte_e_pula_ceasa_atrasada(selecionadas, cfg):
    cortes = avaliacao.cortes(selecionadas, cfg)
    previsor = PrevisorFalso()
    prev = avaliacao.avaliar(previsor, selecionadas, None, cortes, cfg)

    for (maximo_visto, ids), corte in zip(previsor.chamadas, cortes):
        assert maximo_visto <= corte                     # nunca viu dado posterior ao corte
        assert ("MS__tomate" in ids) == (corte <= FIM_MS)  # MS só é prevista enquanto tem dado

    assert set(prev["horizonte"]) == {3, 7, 14}
    assert (prev["ds"] - prev["cutoff"] == pd.to_timedelta(prev["horizonte"], unit="D")).all()
    real = selecionadas.set_index(["unique_id", "ds"])["y"]
    assert np.allclose(prev.set_index(["unique_id", "ds"])["y"], real.loc[prev.set_index(["unique_id", "ds"]).index])


def test_resumir_mede_o_ganho_sobre_o_naive(selecionadas, cfg):
    cortes = avaliacao.cortes(selecionadas, cfg)
    naive = avaliacao.avaliar(PrevisorFalso(), selecionadas, None, cortes, cfg).assign(modelo="Naive")
    pior = naive.assign(modelo="Pior", yhat=naive["yhat"] + 1.0)
    prev = pd.concat([naive, pior], ignore_index=True)
    prev["periodo"] = np.where(prev["cutoff"] == cortes[-1], "holdout", "selecao")

    metricas, por_serie = avaliacao.resumir(prev)
    geral = metricas[(metricas["periodo"] == "todas") & (metricas["horizonte"] == 0)].set_index("modelo")
    assert geral.loc["Naive", "ganho_vs_naive"] == 0
    assert geral.loc["Pior", "ganho_vs_naive"] < 0
    assert set(metricas["horizonte"]) == {0, 3, 7, 14}
    assert set(por_serie["unique_id"]) == set(selecionadas["unique_id"])
