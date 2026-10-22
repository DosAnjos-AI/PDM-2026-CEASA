import pandas as pd
import pytest

from pipeline import campeao


def _prev(erros: dict[str, dict[str, tuple[float, float]]]) -> pd.DataFrame:
    """Previsões sintéticas: erros[modelo][série] = (erro na seleção, erro no holdout)."""
    linhas = []
    for modelo, por_serie in erros.items():
        for uid, (erro_sel, erro_hold) in por_serie.items():
            for periodo, erro in (("selecao", erro_sel), ("holdout", erro_hold)):
                for i in range(5):
                    linhas.append({"modelo": modelo, "unique_id": uid, "periodo": periodo, "horizonte": 7,
                                   "cutoff": pd.Timestamp("2026-01-05") + pd.Timedelta(days=28 * i),
                                   "ds": pd.Timestamp("2026-01-12") + pd.Timedelta(days=28 * i), "y": 10.0, "yhat": 10.0 + erro})
    return pd.DataFrame(linhas)


def test_candidata_so_troca_o_naive_quando_ganha_com_margem(cfg):
    prev = _prev({
        "Naive": {"A": (1.0, 1.0), "B": (1.0, 1.0)},
        "Bom": {"A": (0.5, 0.5), "B": (0.99, 0.99)},   # em B ganha só 1%: abaixo da margem de 3%
    })
    cand = campeao.candidata(prev, cfg).set_index("unique_id")["modelo"]
    assert cand.to_dict() == {"A": "Bom", "B": "Naive"}


def test_decidir_promove_quando_a_candidata_ganha_no_holdout(cfg):
    prev = _prev({"Naive": {"A": (1.0, 1.0), "B": (1.0, 1.0)}, "Bom": {"A": (0.5, 0.5), "B": (0.5, 0.5)}})
    decisao = campeao.decidir(prev, campeao.candidata(prev, cfg), campeao.VERSAO_NAIVE, {}, cfg)
    assert decisao["decisao"] == "promovida"


def test_decidir_rejeita_quando_a_candidata_erra_mais_que_o_naive_no_holdout(cfg):
    # Parece ótimo na seleção, mas piora no holdout: o caso que o holdout existe para pegar.
    prev = _prev({"Naive": {"A": (1.0, 1.0), "B": (1.0, 1.0)}, "Sortudo": {"A": (0.5, 2.0), "B": (0.5, 2.0)}})
    decisao = campeao.decidir(prev, campeao.candidata(prev, cfg), campeao.VERSAO_NAIVE, {}, cfg)
    assert decisao["decisao"] == "rejeitada"
    assert "Naive" in decisao["motivo"]


def test_versao_fixa_coloca_o_mesmo_modelo_em_todas_as_series():
    prev = _prev({"Naive": {"A": (1.0, 1.0), "B": (1.0, 1.0)}, "Chronos2": {"A": (2.0, 2.0), "B": (0.5, 0.5)}})
    fixa = campeao.versao_fixa(prev, "Chronos2")
    assert set(fixa["modelo"]) == {"Chronos2"}
    assert set(fixa["unique_id"]) == {"A", "B"}


def test_versao_fixa_falha_com_modelo_que_nao_esta_ativo():
    prev = _prev({"Naive": {"A": (1.0, 1.0)}})
    with pytest.raises(ValueError, match="não está ativo"):
        campeao.versao_fixa(prev, "Chronos2")
