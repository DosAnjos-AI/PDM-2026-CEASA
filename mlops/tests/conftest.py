"""Dados sintéticos e configuração mínima para os testes do pipeline (sem acesso ao GCP)."""
import os

os.environ.setdefault("N_JOBS", "1")   # statsforecast sem processos paralelos nos testes

import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import pytest  # noqa: E402

FIM = pd.Timestamp("2026-10-19")      # segunda-feira, como a última data real da silver
FIM_MS = pd.Timestamp("2026-10-02")   # CEASA atrasada, como a MS real


def serie(uid: str, inicio: str, fim, semente: int) -> pd.DataFrame:
    """Preço diário em passeio aleatório, sempre positivo."""
    datas = pd.date_range(inicio, fim, freq="D")
    passos = np.random.default_rng(semente).normal(0, 0.05, len(datas))
    return pd.DataFrame({"unique_id": uid, "ds": datas, "y": 5 + np.abs(np.cumsum(passos))})


@pytest.fixture
def cfg() -> dict:
    return {
        "projeto": "teste",
        "fonte": {"tipo": "silver_unificado", "frequencia": "D", "min_periodos": 365, "sazonalidade": 7},
        "clima": {"colunas": ["temp_media_60d"], "defasagem": 14},
        "alertas": {"dias_sem_dados": 7},
        "validacao": {"horizontes": [3, 7, 14], "janelas": 4, "passo": 28, "janelas_holdout": 1,
                      "horizontes_previsao": list(range(1, 15))},
        "campeao": {"margem_serie": 0.03, "limiar_promocao": 0.01},
        "features_ml": {"lags": [1, 2, 7], "medias_moveis": [7], "datas": ["dayofweek"]},
        "modelos": {"Naive": {"ativo": True}},
    }


@pytest.fixture
def series() -> pd.DataFrame:
    """GO ativa até FIM; MS atrasada; um produto que parou em GO; uma série curta em ES."""
    return pd.concat([
        serie("GO__tomate", "2024-01-01", FIM, 1),
        serie("GO__chuchu", "2024-01-01", FIM, 2),
        serie("GO__batata", "2024-01-01", "2026-07-21", 3),   # parou de ser cotada
        serie("MS__tomate", "2024-01-01", FIM_MS, 4),         # CEASA atrasada
        serie("ES__tomate", "2026-01-01", FIM, 5),            # menos que min_periodos
    ], ignore_index=True)


@pytest.fixture
def selecionadas(series, cfg) -> pd.DataFrame:
    from pipeline import dados

    return dados.selecionar_series(series, cfg)[0]
