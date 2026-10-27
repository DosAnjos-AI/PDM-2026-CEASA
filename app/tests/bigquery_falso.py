"""Respostas falsas do BigQuery para testar as páginas sem acesso ao GCP.

Substitui dados._consultar: cada consulta das páginas é reconhecida por trechos do SQL e
respondida com dados sintéticos coerentes entre si (2 CEASAs, uma atrasada como a MS real).
"""
import json

import numpy as np
import pandas as pd

FIM = pd.Timestamp("2026-10-19")
FIM_MS = pd.Timestamp("2026-10-02")
SERIES = ["GO__tomate_longa_vida", "GO__chuchu", "MS__tomate_longa_vida", "MS__chuchu"]
MODELOS = ["Naive", "Chronos2", "ARIMA", "LightGBM_direto"]
RUN = "20261021T000000_teste"
CONFIG = {
    "fonte": {"tipo": "silver_unificado", "tabela": "silver.ceasa_unificado", "coluna_preco": "preco_comum",
              "frequencia": "D"},
    "validacao": {"horizontes": [3, 7, 14], "janelas": 3, "passo": 28, "janelas_holdout": 1,
                  "horizontes_previsao": list(range(1, 15))},
}
CORTES = [pd.Timestamp(d) for d in ("2026-08-10", "2026-09-07", "2026-10-05")]


def _historico() -> pd.DataFrame:
    partes = []
    for i, uid in enumerate(SERIES):
        ceasa, produto = uid.split("__")
        datas = pd.date_range("2025-06-01", FIM_MS if ceasa == "MS" else FIM, freq="D")
        y = 5 + np.abs(np.cumsum(np.random.default_rng(i).normal(0, 0.05, len(datas))))
        partes.append(pd.DataFrame({"unique_id": uid, "ceasa": ceasa, "produto": produto, "ds": datas, "y": y}))
    return pd.concat(partes, ignore_index=True)


HIST = _historico()
ULTIMO = HIST.groupby("unique_id").last()


def _horizontes(modelo: str, publicados: bool) -> list[int]:
    if modelo == "LightGBM_direto" or not publicados:
        return [3, 7, 14]
    return list(range(1, 15))


PREVISOES = pd.DataFrame([
    {"unique_id": uid, "modelo": modelo, "ds": ULTIMO.at[uid, "ds"] + pd.Timedelta(days=h), "horizonte": h,
     "yhat": ULTIMO.at[uid, "y"] * (1 if modelo == "Naive" else 1 + 0.005 * h), "e_campeao": modelo == "Chronos2",
     "ultima_semana": ULTIMO.at[uid, "ds"], "gerado_em": pd.Timestamp("2026-10-21 15:00", tz="UTC"), "run_id": RUN}
    for uid in SERIES for modelo in MODELOS for h in _horizontes(modelo, publicados=True)
])

_y = HIST.set_index(["unique_id", "ds"])["y"]
CV = pd.DataFrame([
    {"unique_id": uid, "modelo": modelo, "cutoff": corte, "ds": corte + pd.Timedelta(days=h), "horizonte": h,
     "y": _y[(uid, corte + pd.Timedelta(days=h))], "yhat": _y[(uid, corte)] * (1 + 0.01 * j)}
    for uid in SERIES for j, modelo in enumerate(MODELOS) for corte in CORTES for h in (3, 7, 14)
    if (uid, corte + pd.Timedelta(days=h)) in _y.index
])

METRICAS = pd.DataFrame([
    {"periodo": periodo, "modelo": modelo, "horizonte": h, "n": 20, "mae": mae, "rmse": mae * 2, "wape": mae / 5,
     "r2": 0.96, "ganho_vs_naive": 1 - mae / 0.5}
    for periodo in ("todas", "selecao", "holdout") for h in (0, 3, 7, 14)
    for modelo, mae in zip(MODELOS, (0.5, 0.48, 0.49, 0.51))
])
METRICAS_SERIE = pd.DataFrame([
    {"modelo": modelo, "unique_id": uid, "n": 9, "mae": mae * (1.1 if uid.startswith("MS") else 0.9)}
    for uid in SERIES for modelo, mae in zip(MODELOS, (0.5, 0.48, 0.49, 0.51))
])
ULTIMA_EXECUCAO = pd.DataFrame([{
    "run_id": RUN, "inicio": pd.Timestamp("2026-10-21 14:53", tz="UTC"), "ultima_semana": FIM, "series_usadas": 4,
    "decisao": "fixada", "tempos_s": json.dumps({m: 10.0 * (i + 1) for i, m in enumerate(MODELOS)}),
    "versao_codigo": "teste", "config": json.dumps(CONFIG),
}])
EXECUCOES = pd.DataFrame([
    {"run_id": RUN, "inicio": pd.Timestamp("2026-10-21 14:53", tz="UTC"), "fim": pd.Timestamp("2026-10-21 15:25", tz="UTC"),
     "status": "sucesso", "origem": "treino-precos-teste", "versao_codigo": "teste", "ultima_semana": FIM,
     "series_usadas": 4, "decisao": "fixada", "erro": None, "experimento": None, "tipo": "treino",
     "segundos_cobrados": 1974, "custo_usd": 0.46},
    {"run_id": "20261020T000000_teste", "inicio": pd.Timestamp("2026-10-20 19:00", tz="UTC"),
     "fim": pd.Timestamp("2026-10-20 19:01", tz="UTC"), "status": "sem_dados_novos", "origem": "treino-precos-teste",
     "versao_codigo": "teste", "ultima_semana": FIM, "series_usadas": 4, "decisao": None, "erro": None,
     "experimento": None, "tipo": "inferencia", "segundos_cobrados": 120, "custo_usd": 0.03},
])
# Última inferência diária: num sábado, depois das previsões publicadas, sem dado novo.
ULTIMA_VERIFICACAO = pd.DataFrame([{"inicio": pd.Timestamp("2026-10-24 19:35", tz="UTC"), "status": "sem_dados_novos"}])
VERSOES = pd.DataFrame([{
    "versao_id": RUN, "criado_em": pd.Timestamp("2026-10-21 15:24", tz="UTC"), "n_series": 4,
    "modelos_usados": json.dumps({"Chronos2": 4}), "mae_holdout_candidata": 0.48, "campeao_anterior": "naive",
    "mae_holdout_campeao": 0.5, "mae_holdout_naive": 0.5, "melhor_modelo_unico": "Chronos2",
    "mae_holdout_modelo_unico": 0.48, "decisao": "fixada", "motivo": "Chronos2 definido pela equipe",
}])
PRODUCAO = pd.DataFrame([{"em": pd.Timestamp("2026-10-21 15:25", tz="UTC"), "versao_id": RUN, "tipo": "fixacao",
                          "motivo": "Chronos2 definido pela equipe"}])


def consultar(sql: str, **params) -> pd.DataFrame:
    s = " ".join(sql.split())
    if "previsoes_cv" in s:
        if "DISTINCT cutoff" in s:
            return pd.DataFrame({"cutoff": sorted(CV["cutoff"].unique())})
        if "DISTINCT unique_id" in s:
            return CV[["unique_id"]].drop_duplicates()
        return CV[CV["unique_id"] == params["uid"]].drop(columns="unique_id")
    if "metricas_serie" in s:
        return METRICAS_SERIE
    if "metricas" in s:
        return METRICAS
    if "execucoes" in s and "@run_id" in s:
        return pd.DataFrame({"tipo": ["inferencia"]})   # previsões atuais vieram da inferência diária
    if "execucoes" in s and "tipo = 'inferencia'" in s:
        return ULTIMA_VERIFICACAO
    if "custo_execucoes" in s:
        return EXECUCOES
    if "execucoes" in s:
        return ULTIMA_EXECUCAO
    if "producao_atual" in s:
        return PRODUCAO[["versao_id"]]
    if "previsoes_atuais" in s:
        return PREVISOES
    if "versoes" in s:
        return VERSOES
    if "producao" in s:
        return PRODUCAO
    if "ceasa_unificado" in s:
        if "@ceasa" in s:
            serie = HIST[(HIST["ceasa"] == params["ceasa"]) & (HIST["produto"] == params["produto"])]
            return serie[["ds", "y"]]
        if "@produto" in s:
            serie = HIST[(HIST["produto"] == params["produto"]) & (HIST["ds"] >= pd.Timestamp(params["desde"]))]
            return serie[["ceasa", "ds", "y"]]
        return HIST.loc[HIST["ds"] >= pd.Timestamp(params["desde"]), ["unique_id", "ds", "y"]]
    raise AssertionError(f"consulta não prevista no BigQuery falso: {s[:150]}")
