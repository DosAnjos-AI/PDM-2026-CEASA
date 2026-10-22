"""Modelos reais (statsforecast e mlforecast) em dados pequenos: pega mudanças de API das bibliotecas."""
import pandas as pd

from pipeline import dados, modelos


def test_naive_preve_a_partir_da_ultima_data_de_cada_serie(selecionadas, cfg):
    p = modelos.criar("Naive", cfg).prever(selecionadas, selecionadas["unique_id"].unique(), 14, None)
    ultimos = selecionadas.groupby("unique_id").agg(ds=("ds", "max"), y=("y", "last"))
    assert p.groupby("unique_id").size().eq(14).all()
    primeiro = p.groupby("unique_id")["ds"].min()
    assert (primeiro == ultimos["ds"] + pd.Timedelta(days=1)).all()
    assert (p.groupby("unique_id")["yhat"].first() == ultimos["y"]).all()


def test_lightgbm_direto_treina_so_os_horizontes_avaliados(selecionadas, cfg):
    cfg["modelos"]["LightGBM_direto"] = {"ativo": True, "tipo": "lightgbm", "estrategia": "direta", "clima": False,
                                         "params": {"n_estimators": 20, "verbosity": -1}}
    ids = ["GO__tomate", "MS__tomate"]
    p = modelos.criar("LightGBM_direto", cfg).prever(selecionadas, ids, 14, None)
    ultimos = selecionadas.groupby("unique_id")["ds"].max()
    horizontes = ((p["ds"] - p["unique_id"].map(ultimos)).dt.days).groupby(p["unique_id"]).apply(set)
    assert horizontes.to_dict() == {uid: {3, 7, 14} for uid in ids}


def test_lightgbm_com_clima_usa_as_covariaveis(selecionadas, cfg):
    cfg["modelos"]["LightGBM_clima"] = {"ativo": True, "tipo": "lightgbm", "estrategia": "direta", "clima": True,
                                        "params": {"n_estimators": 20, "verbosity": -1}}
    bruto = selecionadas[["unique_id", "ds"]].assign(temp_media_60d=selecionadas["ds"].dt.dayofyear.astype(float))
    clima = dados.preparar_clima(None, cfg, selecionadas, bruto)
    p = modelos.criar("LightGBM_clima", cfg).prever(selecionadas, ["GO__tomate"], 14, clima)
    assert len(p) == 3 and p["yhat"].notna().all()
