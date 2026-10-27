"""Consultas ao BigQuery usadas pela aplicação.

A aplicação só lê: tudo o que ela mostra foi gravado pelo pipeline (dataset mlops) ou vem das
camadas silver/gold. Os resultados ficam em cache por 10 minutos.
"""
import json
import os
from datetime import date

import pandas as pd
import streamlit as st
from google.cloud import bigquery

import formato as f

PROJETO = os.environ.get("PROJETO", "pdm-ceasa")
MLOPS = f"`{PROJETO}.mlops`"
FUSO = "America/Sao_Paulo"

_TIPOS = {str: "STRING", int: "INT64", float: "FLOAT64", date: "DATE"}


@st.cache_resource
def _cliente() -> bigquery.Client:
    return bigquery.Client(project=PROJETO)


@st.cache_data(ttl=600, show_spinner="Consultando o BigQuery…")
def _consultar(sql: str, **params) -> pd.DataFrame:
    job_cfg = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter(k, _TIPOS[type(v)], v) for k, v in params.items()]
    )
    df = _cliente().query(sql, job_config=job_cfg).to_dataframe()
    # DATE chega como dbdate; o resto da aplicação trabalha com datetime64.
    for coluna in df.columns:
        if str(df[coluna].dtype) == "dbdate":
            df[coluna] = pd.to_datetime(df[coluna])
    return df


def ultima_execucao() -> pd.Series | None:
    """Última execução de produção que treinou e avaliou os modelos.

    Ignora as execuções "sem dados novos" e os experimentos, que não mexem na produção.
    """
    df = _consultar(f"""
        SELECT run_id, inicio, ultima_semana, series_usadas, decisao, tempos_s, versao_codigo, config
        FROM {MLOPS}.execucoes
        WHERE status = 'sucesso' AND decisao IS NOT NULL AND experimento IS NULL
        ORDER BY inicio DESC LIMIT 1
    """)
    return None if df.empty else df.iloc[0]


def config_da_execucao(execucao: pd.Series) -> dict:
    """Configuração gravada pela execução.

    Execuções até a v0.4 (preço semanal só da CEASA-GO) não têm os campos fonte.tipo,
    fonte.frequencia e validacao.horizontes; eles são preenchidos com os valores daquela época.
    """
    cfg = json.loads(execucao["config"])
    fonte = cfg.setdefault("fonte", {})
    fonte.setdefault("tipo", "analitica_semanal")
    fonte.setdefault("frequencia", "W-MON")
    val = cfg.setdefault("validacao", {})
    val.setdefault("horizontes", list(range(1, val.get("horizonte", 4) + 1)))
    return cfg


def tempos_da_execucao(execucao: pd.Series) -> dict:
    return json.loads(execucao["tempos_s"] or "{}")


def tipo_da_execucao(run_id: str) -> str:
    """treino (avaliação semanal), inferencia (atualização diária pelo Pub/Sub) ou desconhecido."""
    df = _consultar(f"SELECT IFNULL(tipo, 'treino') AS tipo FROM {MLOPS}.execucoes WHERE run_id = @run_id",
                    run_id=run_id)
    return df.iloc[0]["tipo"] if not df.empty else "desconhecido"


def ultima_verificacao() -> pd.Series | None:
    """Última inferência diária (início e status), tenha ela achado dado novo ou não."""
    df = _consultar(f"""
        SELECT inicio, status
        FROM {MLOPS}.execucoes
        WHERE tipo = 'inferencia' AND experimento IS NULL
        ORDER BY inicio DESC LIMIT 1
    """)
    return None if df.empty else df.iloc[0]


def producao_atual() -> str:
    df = _consultar(f"SELECT versao_id FROM {MLOPS}.producao_atual")
    return "naive" if df.empty else df.iloc[0]["versao_id"]


def previsoes_atuais() -> pd.DataFrame:
    df = _consultar(f"""
        SELECT unique_id, modelo, ds, horizonte, yhat, e_campeao, ultima_semana, gerado_em, run_id
        FROM {MLOPS}.previsoes_atuais
    """)
    return f.com_partes(df)


def historico(unique_id: str, cfg: dict) -> pd.DataFrame:
    """Preço real de uma série (só períodos já fechados)."""
    ceasa, produto, classe = f.dividir(unique_id)
    if cfg["fonte"]["tipo"] == "silver_unificado":
        return _consultar(f"""
            SELECT data AS ds, {cfg['fonte']['coluna_preco']} AS y
            FROM `{PROJETO}.{cfg['fonte']['tabela']}`
            WHERE ceasa = @ceasa AND produto_canonico = @produto
            ORDER BY ds
        """, ceasa=ceasa, produto=produto)
    df = _consultar(f"""
        SELECT data_inicio_semana AS ds, {cfg['fonte']['coluna_preco']} AS y
        FROM `{PROJETO}.{cfg['fonte']['tabela']}`
        WHERE produto = @produto AND classe = @classe
        ORDER BY ds
    """, produto=produto, classe=int(classe))
    hoje = pd.Timestamp.now(tz=FUSO).tz_localize(None).normalize()
    return df[df["ds"] + pd.Timedelta(days=7) <= hoje]   # semana em andamento ainda não fechou


def produto_em_todas_as_ceasas(produto: str, desde: date, cfg: dict) -> pd.DataFrame:
    """Preço diário de um produto em todas as CEASAs (só na fonte silver, em R$/kg)."""
    return _consultar(f"""
        SELECT ceasa, data AS ds, {cfg['fonte']['coluna_preco']} AS y
        FROM `{PROJETO}.{cfg['fonte']['tabela']}`
        WHERE produto_canonico = @produto AND data >= @desde
        ORDER BY ceasa, ds
    """, produto=produto, desde=desde)


def ultimos_precos(previsoes: pd.DataFrame, cfg: dict) -> pd.DataFrame:
    """Preço real na última data de cada série (a base de onde as previsões partem)."""
    desde = (previsoes["ultima_semana"].min() - pd.Timedelta(days=1)).date()
    if cfg["fonte"]["tipo"] == "silver_unificado":
        df = _consultar(f"""
            SELECT CONCAT(ceasa, '__', produto_canonico) AS unique_id, data AS ds, {cfg['fonte']['coluna_preco']} AS y
            FROM `{PROJETO}.{cfg['fonte']['tabela']}`
            WHERE data >= @desde
        """, desde=desde)
    else:
        df = _consultar(f"""
            SELECT CONCAT(produto, '__c', CAST(classe AS STRING)) AS unique_id, data_inicio_semana AS ds,
                   {cfg['fonte']['coluna_preco']} AS y
            FROM `{PROJETO}.{cfg['fonte']['tabela']}`
            WHERE data_inicio_semana >= @desde
        """, desde=desde)
    base = previsoes[["unique_id", "ultima_semana"]].drop_duplicates()
    return base.merge(df, left_on=["unique_id", "ultima_semana"], right_on=["unique_id", "ds"])[["unique_id", "y"]]


def previsoes_cv(run_id: str, unique_id: str) -> pd.DataFrame:
    return _consultar(f"""
        SELECT modelo, cutoff, ds, horizonte, y, yhat
        FROM {MLOPS}.previsoes_cv
        WHERE run_id = @run_id AND unique_id = @uid
        ORDER BY modelo, cutoff, ds
    """, run_id=run_id, uid=unique_id)


def cortes_cv(run_id: str) -> list[pd.Timestamp]:
    """Datas de corte do walk-forward da execução (as mesmas para todas as séries)."""
    df = _consultar(f"SELECT DISTINCT cutoff FROM {MLOPS}.previsoes_cv WHERE run_id = @run_id ORDER BY cutoff",
                    run_id=run_id)
    return list(df["cutoff"])


def series_cv(run_id: str) -> list[str]:
    df = _consultar(f"SELECT DISTINCT unique_id FROM {MLOPS}.previsoes_cv WHERE run_id = @run_id", run_id=run_id)
    return df["unique_id"].tolist()


def metricas(run_id: str) -> pd.DataFrame:
    return _consultar(f"""
        SELECT periodo, modelo, horizonte, n, mae, rmse, wape, r2, ganho_vs_naive
        FROM {MLOPS}.metricas
        WHERE run_id = @run_id
    """, run_id=run_id)


def metricas_serie(run_id: str) -> pd.DataFrame:
    df = _consultar(f"""
        SELECT modelo, unique_id, n, mae
        FROM {MLOPS}.metricas_serie
        WHERE run_id = @run_id
    """, run_id=run_id)
    return f.com_partes(df)


def execucoes() -> pd.DataFrame:
    return _consultar(f"""
        SELECT e.run_id, e.inicio, e.fim, e.status, e.origem, e.versao_codigo, e.ultima_semana,
               e.series_usadas, e.decisao, e.erro, e.experimento, IFNULL(e.tipo, 'treino') AS tipo,
               c.segundos_cobrados, c.custo_usd
        FROM {MLOPS}.execucoes e
        LEFT JOIN {MLOPS}.custo_execucoes c USING (run_id)
        ORDER BY e.inicio DESC
    """)


def versoes() -> pd.DataFrame:
    return _consultar(f"""
        SELECT versao_id, criado_em, n_series, modelos_usados, mae_holdout_candidata, campeao_anterior,
               mae_holdout_campeao, mae_holdout_naive, melhor_modelo_unico, mae_holdout_modelo_unico,
               decisao, motivo
        FROM {MLOPS}.versoes
        ORDER BY criado_em DESC
    """)


def historico_producao() -> pd.DataFrame:
    return _consultar(f"SELECT em, versao_id, tipo, motivo FROM {MLOPS}.producao ORDER BY em DESC")
