"""Leitura das séries de preço e do clima no BigQuery.

Duas fontes, escolhidas em fonte.tipo no yaml:
- silver_unificado: preço diário por kg de todas as CEASAs (série = CEASA__produto), com o clima
  do estado já na mesma tabela;
- analitica_semanal: preço semanal por embalagem só da CEASA-GO (série = produto__cclasse), com o
  clima de Goiânia calculado aqui. É a configuração usada até a v0.4.
"""
import hashlib
import logging
from datetime import date

import pandas as pd
from google.cloud import bigquery

log = logging.getLogger(__name__)


def passo(cfg: dict) -> pd.Timedelta:
    """Duração de um período da série: 1 dia ou 1 semana."""
    return pd.Timedelta(days=1) if cfg["fonte"]["frequencia"] == "D" else pd.Timedelta(weeks=1)


def grupo(unique_id: str, cfg: dict) -> str:
    """CEASA da série. Na fonte semanal antiga todas as séries são da CEASA-GO."""
    return unique_id.split("__", 1)[0] if cfg["fonte"]["tipo"] == "silver_unificado" else "GO"


def carregar(cliente: bigquery.Client, cfg: dict, hoje: date) -> tuple[pd.DataFrame, pd.DataFrame | None]:
    """Devolve (séries no formato unique_id/ds/y, clima bruto por série ou None)."""
    tipo = cfg["fonte"]["tipo"]
    if tipo == "silver_unificado":
        return _silver(cliente, cfg)
    if tipo == "analitica_semanal":
        return descartar_semana_incompleta(_analitica(cliente, cfg), hoje), None
    raise ValueError(f"fonte.tipo desconhecido: {tipo}")


def _consultar(cliente: bigquery.Client, sql: str, params: list) -> pd.DataFrame:
    df = cliente.query(sql, job_config=bigquery.QueryJobConfig(query_parameters=params)).to_dataframe()
    df["ds"] = pd.to_datetime(df["ds"])
    df["y"] = df["y"].astype(float)
    return df.sort_values(["unique_id", "ds"]).reset_index(drop=True)


def _silver(cliente: bigquery.Client, cfg: dict) -> tuple[pd.DataFrame, pd.DataFrame]:
    fonte, colunas = cfg["fonte"], cfg.get("clima", {}).get("colunas", [])
    clima_sql = "".join(f", {c}" for c in colunas)
    sql = f"""
        SELECT CONCAT(ceasa, '__', produto_canonico) AS unique_id, data AS ds,
               {fonte['coluna_preco']} AS y{clima_sql}
        FROM `{cfg['projeto']}.{fonte['tabela']}`
        WHERE ceasa IN UNNEST(@ceasas) AND data >= @data_inicio AND {fonte['coluna_preco']} IS NOT NULL
    """
    df = _consultar(cliente, sql, [
        bigquery.ArrayQueryParameter("ceasas", "STRING", fonte["ceasas"]),
        bigquery.ScalarQueryParameter("data_inicio", "DATE", fonte["data_inicio"]),
    ])
    return df[["unique_id", "ds", "y"]], df[["unique_id", "ds", *colunas]]


def _analitica(cliente: bigquery.Client, cfg: dict) -> pd.DataFrame:
    fonte = cfg["fonte"]
    sql = f"""
        SELECT CONCAT(produto, '__c', CAST(classe AS STRING)) AS unique_id,
               data_inicio_semana AS ds,
               {fonte['coluna_preco']} AS y
        FROM `{cfg['projeto']}.{fonte['tabela']}`
        WHERE data_inicio_semana >= @data_inicio
          AND {fonte['coluna_preco']} IS NOT NULL
    """
    return _consultar(cliente, sql, [bigquery.ScalarQueryParameter("data_inicio", "DATE", fonte["data_inicio"])])


def descartar_semana_incompleta(df: pd.DataFrame, hoje: date) -> pd.DataFrame:
    """A semana que começa em ds só está fechada a partir da segunda-feira seguinte.

    Sem isso, a média de uma semana com 2 ou 3 pregões entraria no treino como se fosse
    o preço da semana inteira, e mudaria a cada nova carga do gold.
    """
    fechada = df["ds"] + pd.Timedelta(weeks=1) <= pd.Timestamp(hoje)
    if (~fechada).any():
        log.info("Descartando semana incompleta: %s", sorted(df.loc[~fechada, "ds"].dt.date.unique()))
    return df[fechada]


def verificar_atraso(df: pd.DataFrame, cfg: dict, hoje: date) -> dict[str, int]:
    """CEASAs cujo último dado é mais antigo que alertas.dias_sem_dados.

    Cada uma gera no log uma linha com ALERTA_DADOS_ATRASADOS, que dispara o alerta configurado
    no Cloud Monitoring (ver infra/alertas). Devolve {CEASA: dias sem dados}.
    """
    limite = cfg.get("alertas", {}).get("dias_sem_dados")
    if not limite:
        return {}
    ultimas = df.groupby(df["unique_id"].map(lambda u: grupo(u, cfg)))["ds"].max()
    dias = (pd.Timestamp(hoje) - ultimas).dt.days
    atrasadas = {g: int(n) for g, n in dias.items() if n > limite}
    for g, n in atrasadas.items():
        log.warning("ALERTA_DADOS_ATRASADOS: CEASA %s sem dados há %d dias (último dado em %s; limite de %d dias)",
                    g, n, ultimas[g].date(), limite)
    return atrasadas


def selecionar_series(df: pd.DataFrame, cfg: dict) -> tuple[pd.DataFrame, dict]:
    """Mantém as séries ainda cotadas, cortadas no último trecho sem buracos.

    Uma série está ativa se chega até a última data da sua CEASA: cada CEASA pode estar
    atualizada até um dia diferente (ex.: MS atrasada), mas um produto que parou de ser cotado
    enquanto a CEASA continua (ex.: batata inglesa em GO) fica de fora.
    """
    d = passo(cfg)
    grupos = df["unique_id"].map(lambda u: grupo(u, cfg))
    fim_grupo = df.groupby(grupos)["ds"].transform("max")
    fim_serie = df.groupby("unique_id")["ds"].transform("max")
    ativas = df[fim_serie == fim_grupo]

    quebra = ativas.groupby("unique_id")["ds"].diff().ne(d)
    trecho = quebra.groupby(ativas["unique_id"]).cumsum()
    continuas = ativas[trecho == trecho.groupby(ativas["unique_id"]).transform("max")]

    tamanho = continuas.groupby("unique_id")["ds"].transform("size")
    final = continuas[tamanho >= cfg["fonte"]["min_periodos"]].reset_index(drop=True)

    por_grupo = final.groupby(final["unique_id"].map(lambda u: grupo(u, cfg))).agg(
        series=("unique_id", "nunique"), ultima_data=("ds", "max"),
    )
    resumo = {
        "series_lidas": int(df["unique_id"].nunique()),
        "series_ativas": int(ativas["unique_id"].nunique()),
        "series_usadas": int(final["unique_id"].nunique()),
        "ultima_data": final["ds"].max().date().isoformat(),
        "linhas": int(len(final)),
        "por_ceasa": {g: f"{int(r.series)} séries até {r.ultima_data.date()}" for g, r in por_grupo.iterrows()},
    }
    log.info("Séries: %s", resumo)
    return final, resumo


def preparar_clima(cliente: bigquery.Client, cfg: dict, df: pd.DataFrame,
                   clima_bruto: pd.DataFrame | None) -> pd.DataFrame:
    """Clima por série já defasado: a linha (série, ds) traz o clima de ds - defasagem.

    Cobre o histórico de cada série e os períodos futuros a prever, de modo que tanto o treino
    quanto a previsão só usem clima já conhecido no dia da previsão.
    """
    ccfg, d, val = cfg["clima"], passo(cfg), cfg["validacao"]
    defasagem = ccfg["defasagem"]
    # Maior horizonte entre os avaliados e os publicados: a previsão final pode ir além da avaliação.
    h = max([*val["horizontes"], *val.get("horizontes_previsao", [])])
    if defasagem < h:
        raise ValueError("clima.defasagem precisa ser >= maior horizonte para não usar clima futuro")

    if clima_bruto is None:
        base = _clima_goiania_semanal(cliente, cfg)
        clima_bruto = (
            df[["unique_id"]].drop_duplicates().merge(base, how="cross")
        )
    colunas = [c for c in clima_bruto.columns if c not in ("unique_id", "ds")]

    limites = df.groupby("unique_id")["ds"].agg(["min", "max"])
    partes = []
    for uid, g in clima_bruto[clima_bruto["unique_id"].isin(limites.index)].groupby("unique_id"):
        serie = g.set_index("ds")[colunas].sort_index()
        serie.index = serie.index + defasagem * d   # o valor do dia t passa para a linha t + defasagem
        grade = pd.date_range(limites.at[uid, "min"], limites.at[uid, "max"] + h * d, freq=cfg["fonte"]["frequencia"])
        # Dias ainda sem medição repetem o último valor; o começo do histórico repete o primeiro.
        serie = serie.reindex(serie.index.union(grade)).ffill().bfill().reindex(grade)
        partes.append(serie.rename_axis("ds").reset_index().assign(unique_id=uid))

    clima = pd.concat(partes, ignore_index=True)
    return clima.rename(columns={c: f"{c}_l{defasagem}" for c in colunas})


def _clima_goiania_semanal(cliente: bigquery.Client, cfg: dict) -> pd.DataFrame:
    """Clima semanal de Goiânia a partir do dado diário (usado pela fonte semanal antiga)."""
    ccfg = cfg["clima"]
    # Quando há medição (ERA5) e previsão para o mesmo dia, fica a medição.
    sql = f"""
        WITH dia AS (
          SELECT data,
                 ARRAY_AGG(STRUCT(temp_media, umidade_media, precipitacao_mm)
                           ORDER BY IF(STARTS_WITH(fonte, 'open-meteo-archive'), 0, 1) LIMIT 1)[OFFSET(0)] AS c
          FROM `{cfg['projeto']}.{ccfg['tabela']}`
          WHERE cidade = @cidade
          GROUP BY data
        )
        SELECT DATE_TRUNC(data, ISOWEEK) AS ds,
               AVG(c.temp_media) AS temp,
               AVG(c.umidade_media) AS umidade,
               SUM(c.precipitacao_mm) AS chuva
        FROM dia
        GROUP BY ds
    """
    job_cfg = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("cidade", "STRING", ccfg["cidade"])]
    )
    semanal = cliente.query(sql, job_config=job_cfg).to_dataframe()
    semanal["ds"] = pd.to_datetime(semanal["ds"])
    semanal = semanal.set_index("ds").sort_index().asfreq("W-MON").astype(float)
    semanal["chuva_4s"] = semanal["chuva"].rolling(4, min_periods=1).sum()
    semanal["chuva_12s"] = semanal["chuva"].rolling(12, min_periods=1).sum()
    return semanal.reset_index()


def com_clima(df: pd.DataFrame, clima: pd.DataFrame | None) -> pd.DataFrame:
    if clima is None:
        raise ValueError("modelo com clima: true, mas o clima não foi carregado")
    out = df.merge(clima, on=["unique_id", "ds"], how="left")
    if out.isna().any().any():
        raise ValueError("faltam features de clima para algumas datas")
    return out


def versao_dados(df: pd.DataFrame) -> str:
    """Impressão digital do conjunto usado, para saber se duas execuções viram os mesmos dados."""
    hashes = pd.util.hash_pandas_object(df[["unique_id", "ds", "y"]], index=False).values
    return hashlib.md5(hashes.tobytes()).hexdigest()[:12]
