"""Destaques do cartão de preço, com séries sintéticas de resultado conhecido."""
import numpy as np
import pandas as pd

import destaques as d
import formato as f

FIM = pd.Timestamp("2026-10-26")


def serie(inicio: str, valores) -> pd.DataFrame:
    datas = pd.date_range(inicio, FIM, freq="D")
    return pd.DataFrame({"ds": datas, "y": valores(datas)})


def test_tendencia_compara_a_ultima_semana_com_a_de_3_meses_antes():
    h = serie("2026-01-01", lambda ds: np.where(ds >= "2026-10-01", 12.0, 10.0))
    assert abs(d.tendencia(h, FIM) - 0.2) < 1e-9
    assert d.tendencia(h.tail(30), FIM) is None   # sem dado de 3 meses antes


def test_extremos_olha_so_os_ultimos_2_anos():
    h = serie("2023-01-01", lambda ds: np.full(len(ds), 5.0))
    h.loc[h["ds"] == "2023-06-01", "y"] = 50.0   # fora da janela: ignorado
    h.loc[h["ds"] == "2025-05-14", "y"] = 9.0
    h.loc[h["ds"] == "2025-09-02", "y"] = 2.0
    e = d.extremos(h, FIM)
    assert (e["pico"], e["data_pico"]) == (9.0, pd.Timestamp("2025-05-14"))
    assert (e["minima"], e["data_minima"]) == (2.0, pd.Timestamp("2025-09-02"))
    assert abs(e["variacao"] - 3.5) < 1e-9
    assert d.mes_ano(e["data_pico"]) == "mai/25"


def test_mes_mais_barato_desconta_a_inflacao_de_cada_ano():
    # O preço sobe 20% ao ano, mas setembro é sempre 30% mais barato que o resto do ano.
    h = serie("2019-01-01", lambda ds: 10 * 1.2 ** (ds.year - 2019) * np.where(ds.month == 9, 0.7, 1.0))
    assert d.mes_mais_barato(h, FIM) == 9
    assert d.mes_mais_barato(h[h["ds"] >= "2025-01-01"], FIM) is None   # só um ano completo


def test_comparar_ceasas_deixa_de_fora_a_ceasa_atrasada():
    todas = pd.DataFrame({
        "ceasa": ["GO", "MG", "MS", "GO", "MG"],
        "ds": pd.to_datetime(["2026-10-23", "2026-10-23", "2026-10-02", "2026-10-26", "2026-10-26"]),
        "y": [10.0, 7.0, 1.0, 10.0, 6.0],
    })
    c = d.comparar_ceasas(todas, "GO", FIM)
    assert (c["ceasa"], c["preco"], c["n_ceasas"]) == ("MG", 6.0, 2)
    assert abs(c["diferenca"] - 0.4) < 1e-9
    assert d.comparar_ceasas(todas, "MG", FIM)["diferenca"] < 0   # MG já é a mais barata
    assert d.comparar_ceasas(todas[todas["ceasa"] == "GO"], "GO", FIM) is None   # nada para comparar


def test_nomes_dos_produtos_com_acento_e_artigo():
    assert f.nome_produto("maca_fuji") == "Maçã Fuji"
    assert f.nome_produto("produto_novo") == "Produto novo"   # fora da lista: como antes
    assert f.feminino("batata_inglesa") and not f.feminino("tomate_longa_vida")
    assert f.dia_da_semana("2026-11-02") == "segunda, 02/11/2026"
