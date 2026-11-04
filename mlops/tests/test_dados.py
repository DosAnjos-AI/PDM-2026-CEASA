from datetime import date

import pandas as pd
import pytest

from conftest import FIM, FIM_MS, serie
from pipeline import dados


def test_selecao_mantem_ceasa_atrasada_e_descarta_produto_parado_e_serie_curta(series, cfg):
    final, resumo = dados.selecionar_series(series, cfg)
    assert set(final["unique_id"]) == {"GO__tomate", "GO__chuchu", "MS__tomate"}
    assert final.loc[final["unique_id"] == "MS__tomate", "ds"].max() == FIM_MS
    assert resumo["ultima_data"] == FIM.date().isoformat()


def test_selecao_corta_a_serie_no_ultimo_trecho_sem_buracos(series, cfg):
    buraco = (series["unique_id"] == "GO__tomate") & series["ds"].between("2025-01-10", "2025-01-12")
    final, _ = dados.selecionar_series(series[~buraco], cfg)
    tomate = final[final["unique_id"] == "GO__tomate"]
    assert tomate["ds"].min() == pd.Timestamp("2025-01-13")
    assert tomate["ds"].diff().dropna().eq(pd.Timedelta(days=1)).all()


def test_verificar_atraso_aponta_so_a_ceasa_atrasada(series, cfg):
    # GO tem um produto parado, mas a CEASA continua atualizada: só a MS passa do limite.
    assert dados.verificar_atraso(series, cfg, date(2026, 10, 21)) == {"MS": 19}


def test_verificar_atraso_desligado_sem_limite_na_config(series, cfg):
    cfg.pop("alertas")
    assert dados.verificar_atraso(series, cfg, date(2026, 10, 21)) == {}


def test_periodos_de_atraso_so_cresce_na_serie_atrasada(cfg):
    ultimo = pd.Series({"GO__hoje": FIM, "GO__ontem": FIM - pd.Timedelta(days=1), "MS__tomate": FIM_MS})
    extra = dados.periodos_de_atraso(ultimo, FIM.date(), cfg)
    # Dado de hoje ou de ontem: a previsão já começa amanhã ou hoje. MS, parada em 02/10: prevê 16 dias a
    # mais (03/10 a 18/10, a véspera de hoje) para que os 14 publicados comecem hoje, 19/10.
    assert extra.to_dict() == {"GO__hoje": 0, "GO__ontem": 0, "MS__tomate": 16}
    assert dados.periodos_de_atraso(ultimo, None, cfg).eq(0).all()


def test_periodos_de_atraso_na_fonte_semanal(cfg):
    cfg["fonte"]["frequencia"] = "W-MON"
    # Quarta-feira: a última semana fechada começa na segunda de 9 dias antes; 3 semanas antes, atrasada.
    ultimo = pd.Series({"em_dia": pd.Timestamp("2026-10-26"), "atrasada": pd.Timestamp("2026-10-05")})
    assert dados.periodos_de_atraso(ultimo, date(2026, 11, 4), cfg).to_dict() == {"em_dia": 0, "atrasada": 3}


def _clima_bruto(df: pd.DataFrame) -> pd.DataFrame:
    """Clima com valor = número do dia, para saber exatamente de que data veio cada valor."""
    base = pd.Timestamp("2020-01-01")
    return df[["unique_id", "ds"]].assign(temp_media_60d=(df["ds"] - base).dt.days.astype(float))


def test_clima_defasado_so_usa_dado_de_14_dias_antes(selecionadas, cfg):
    clima = dados.preparar_clima(None, cfg, selecionadas, _clima_bruto(selecionadas))
    coluna = "temp_media_60d_l14"
    base = pd.Timestamp("2020-01-01")
    inicio = selecionadas.groupby("unique_id")["ds"].min()
    validas = clima[clima["ds"] - pd.Timedelta(days=14) >= clima["unique_id"].map(inicio)]
    esperado = (validas["ds"] - pd.Timedelta(days=14) - base).dt.days
    assert (validas[coluna] == esperado).all()


def test_clima_cobre_os_dias_previstos_de_cada_serie(selecionadas, cfg):
    cfg["validacao"]["horizontes"] = [3, 7]   # avaliação curta, mas a publicação vai até 14 dias
    clima = dados.preparar_clima(None, cfg, selecionadas, _clima_bruto(selecionadas))
    fim_clima = clima.groupby("unique_id")["ds"].max()
    fim_serie = selecionadas.groupby("unique_id")["ds"].max()
    assert (fim_clima == fim_serie + pd.Timedelta(days=14)).all()


def test_clima_da_serie_atrasada_chega_aos_14_dias_a_partir_de_hoje(selecionadas, cfg):
    hoje = FIM + pd.Timedelta(days=1)
    clima = dados.preparar_clima(None, cfg, selecionadas, _clima_bruto(selecionadas), hoje.date())
    fim_clima = clima.groupby("unique_id")["ds"].max()
    assert fim_clima["GO__tomate"] == FIM + pd.Timedelta(days=14)          # atualizada: igual a antes
    assert fim_clima["MS__tomate"] == hoje + pd.Timedelta(days=13)         # atrasada: hoje + 13 dias
    ms = clima[clima["unique_id"] == "MS__tomate"].set_index("ds")["temp_media_60d_l14"]
    # Sem clima depois do último dado da MS, os dias seguintes repetem o último valor conhecido.
    assert (ms[ms.index > FIM_MS + pd.Timedelta(days=14)] == ms[FIM_MS + pd.Timedelta(days=14)]).all()
    assert not clima.isna().any().any()


def test_clima_exige_defasagem_maior_ou_igual_ao_horizonte(selecionadas, cfg):
    cfg["clima"]["defasagem"] = 7
    with pytest.raises(ValueError, match="defasagem"):
        dados.preparar_clima(None, cfg, selecionadas, _clima_bruto(selecionadas))


def test_com_clima_falha_quando_falta_clima():
    df = serie("GO__tomate", "2026-01-01", "2026-01-10", 1)
    clima = df[["unique_id", "ds"]].iloc[:5].assign(temp=1.0)
    with pytest.raises(ValueError, match="faltam features de clima"):
        dados.com_clima(df, clima)
