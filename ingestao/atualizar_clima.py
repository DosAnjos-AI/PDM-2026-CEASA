"""Atualizacao diaria de pdm-ceasa.bronze.clima_historico (observado + previsao).

Faz, para cada uma das 5 cidades:
  1. Observado: le na bronze o ultimo dia observado (ERA5) e as datas hoje
     marcadas como previsao; pede a Archive API do Open-Meteo com
     models=era5 explicito (sem ele a API mistura ECMWF IFS e nao tem delay)
     do dia seguinte ao ultimo observado ate hoje. Cada data com as 5
     variaveis nao nulas vira observado (fonte 'open-meteo-archive-api/era5');
     data ainda nula (delay do ERA5, medido em ~7 dias) e pulada, nao e erro.
  2. Previsao: do dia seguinte ao ultimo observado disponivel ate o teto do
     modelo -- best_match (16 dias contando hoje); se falhar, ecmwf_ifs025
     (15 dias). fonte = 'open-meteo-forecast-api/<modelo usado>'.
  3. Grava tudo com um unico MERGE por (data, estado). O MERGE nunca troca
     observado por previsao. data_coleta = hoje (America/Sao_Paulo).

Idempotente: reexecutar no mesmo dia regrava as mesmas linhas com os mesmos
valores (salvo atualizacao da previsao pela propria API).

Falha ruidosa: erro de rede/HTTP em qualquer cidade, ou as duas chamadas de
previsao falhando, e logado com severity ERROR e o processo termina com
codigo 1 -- a execucao aparece como falha no Cloud Run e no Cloud Logging.
As linhas das cidades que deram certo sao gravadas mesmo assim.

Nao faz: nao cria tabela, nao reprocessa a serie historica, nao altera o
schema da bronze.

Uso:
  python ingestao/atualizar_clima.py             # grava na bronze
  python ingestao/atualizar_clima.py --simular   # tudo menos o MERGE

Credenciais: Application Default Credentials (local: gcloud auth
application-default login; Cloud Run: service account do job).

Fonte dos dados: Open-Meteo (https://open-meteo.com), licenca CC BY 4.0 --
Archive API (reanalise ERA5, Copernicus/ECMWF) e Forecast API. Uso gratuito
nao comercial, sem chave de API.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from google.cloud import bigquery

PROJETO = os.environ.get("PROJETO", "pdm-ceasa")
TABELA = f"{PROJETO}.bronze.clima_historico"
FUSO = "America/Sao_Paulo"
TIMEOUT_HTTP = 60

URL_ARCHIVE = "https://archive-api.open-meteo.com/v1/archive"
URL_FORECAST = "https://api.open-meteo.com/v1/forecast"
FONTE_OBSERVADO = "open-meteo-archive-api/era5"
PREFIXO_PREVISAO = "open-meteo-forecast-api"
# modelos de previsao em ordem de preferencia e o forecast_days maximo de cada um
MODELOS_PREVISAO = [("best_match", 16), ("ecmwf_ifs025", 15)]
PAST_DAYS_MAX = 92

# coordenadas do geocoding Open-Meteo (decisao registrada: nao reprocessar o historico)
CIDADES = {
    "GO": ("Goiânia", -16.67861, -49.25389),
    "ES": ("Cariacica", -20.26389, -40.42),
    "MG": ("Contagem", -19.93167, -44.05361),
    "MS": ("Campo Grande", -20.44278, -54.64639),
    "SC": ("São José", -27.61528, -48.6275),
}

# coluna da bronze <- variavel diaria da API (ja agregada por dia, vento em km/h)
VARIAVEIS = {
    "temp_media": "temperature_2m_mean",
    "umidade_media": "relative_humidity_2m_mean",
    "nebulosidade_media": "cloud_cover_mean",
    "precipitacao_mm": "precipitation_sum",
    "vento_max_kmh": "wind_speed_10m_max",
}

# schema da bronze (inalterado), usado para tipar as linhas enviadas ao MERGE
TIPOS = {"data": "DATE", "cidade": "STRING", "estado": "STRING",
         **{coluna: "FLOAT64" for coluna in VARIAVEIS},
         "fonte": "STRING", "data_coleta": "DATE"}

SQL_ESTADO = f"""
SELECT
  estado,
  MAX(IF(STARTS_WITH(fonte, 'open-meteo-archive-api'), data, NULL)) AS ultimo_observado,
  ARRAY_AGG(IF(STARTS_WITH(fonte, '{PREFIXO_PREVISAO}'), data, NULL) IGNORE NULLS) AS datas_previsao
FROM `{TABELA}`
GROUP BY estado
"""

SQL_MERGE = f"""
MERGE `{TABELA}` AS t
USING (SELECT * FROM UNNEST(@linhas)) AS s
ON t.data = s.data AND t.estado = s.estado
WHEN MATCHED AND NOT (
  STARTS_WITH(t.fonte, 'open-meteo-archive-api') AND STARTS_WITH(s.fonte, '{PREFIXO_PREVISAO}')
) THEN UPDATE SET
  cidade = s.cidade,
  temp_media = s.temp_media,
  umidade_media = s.umidade_media,
  nebulosidade_media = s.nebulosidade_media,
  precipitacao_mm = s.precipitacao_mm,
  vento_max_kmh = s.vento_max_kmh,
  fonte = s.fonte,
  data_coleta = s.data_coleta
WHEN NOT MATCHED THEN INSERT
  (data, cidade, estado, temp_media, umidade_media, nebulosidade_media,
   precipitacao_mm, vento_max_kmh, fonte, data_coleta)
VALUES
  (s.data, s.cidade, s.estado, s.temp_media, s.umidade_media, s.nebulosidade_media,
   s.precipitacao_mm, s.vento_max_kmh, s.fonte, s.data_coleta)
"""


class FormatoCloudLogging(logging.Formatter):
    """Uma linha JSON por log; o Cloud Logging le o campo severity."""

    def format(self, record: logging.LogRecord) -> str:
        return json.dumps({"severity": record.levelname, "message": record.getMessage()},
                          ensure_ascii=False)


log = logging.getLogger("atualizar_clima")


def chamar_api(url: str, params: dict) -> dict:
    """GET na API do Open-Meteo; erro HTTP vira RuntimeError com o motivo da API."""
    endereco = url + "?" + urllib.parse.urlencode(params)
    try:
        with urllib.request.urlopen(endereco, timeout=TIMEOUT_HTTP) as resposta:
            return json.load(resposta)
    except urllib.error.HTTPError as erro:
        raise RuntimeError(f"HTTP {erro.code} em {url}: {erro.read().decode()[:300]}") from erro
    except urllib.error.URLError as erro:
        raise RuntimeError(f"falha de rede em {url}: {erro.reason}") from erro


def dias_completos(resposta: dict) -> dict[date, dict[str, float]]:
    """Datas em que as 5 variaveis vieram nao nulas, ja com o nome da coluna da bronze."""
    diario = resposta["daily"]
    saida = {}
    for i, texto in enumerate(diario["time"]):
        valores = {col: diario[var][i] for col, var in VARIAVEIS.items()}
        if all(v is not None for v in valores.values()):
            saida[date.fromisoformat(texto)] = valores
    return saida


def buscar_observado(lat: float, lon: float, inicio: date, fim: date) -> dict[date, dict[str, float]]:
    if inicio > fim:
        return {}
    resposta = chamar_api(URL_ARCHIVE, {
        "latitude": lat, "longitude": lon, "models": "era5", "timezone": FUSO,
        "daily": ",".join(VARIAVEIS.values()),
        "start_date": inicio.isoformat(), "end_date": fim.isoformat(),
    })
    return dias_completos(resposta)


def buscar_previsao(lat: float, lon: float, inicio: date, hoje: date) -> tuple[str, dict[date, dict[str, float]]]:
    """Tenta cada modelo em ordem; devolve (modelo usado, dias de inicio em diante)."""
    past_days = max((hoje - inicio).days, 0)
    if past_days > PAST_DAYS_MAX:
        raise RuntimeError(f"lacuna de {past_days} dias excede past_days={PAST_DAYS_MAX} da Forecast API")
    falhas = []
    for modelo, forecast_days in MODELOS_PREVISAO:
        try:
            resposta = chamar_api(URL_FORECAST, {
                "latitude": lat, "longitude": lon, "models": modelo, "timezone": FUSO,
                "daily": ",".join(VARIAVEIS.values()),
                "past_days": past_days, "forecast_days": forecast_days,
            })
            dias = {d: v for d, v in dias_completos(resposta).items() if d >= inicio}
            if not dias:
                raise RuntimeError("resposta sem nenhum dia completo")
            return modelo, dias
        except (RuntimeError, KeyError) as erro:
            log.warning(f"previsao com {modelo} falhou: {erro}")
            falhas.append(f"{modelo}: {erro}")
    raise RuntimeError("todos os modelos de previsao falharam -- " + " | ".join(falhas))


def montar_linha(estado: str, cidade: str, dia: date, valores: dict, fonte: str, hoje: date) -> dict:
    return {"data": dia, "cidade": cidade, "estado": estado, **valores, "fonte": fonte, "data_coleta": hoje}


def gravar(cliente: bigquery.Client, linhas: list[dict], simular: bool) -> int:
    estruturas = [
        bigquery.StructQueryParameter(None, *[
            bigquery.ScalarQueryParameter(coluna, tipo, linha[coluna]) for coluna, tipo in TIPOS.items()
        ])
        for linha in linhas
    ]
    config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ArrayQueryParameter("linhas", "STRUCT", estruturas)],
        dry_run=simular,
    )
    job = cliente.query(SQL_MERGE, job_config=config)
    if simular:
        log.info(f"MERGE validado em dry_run (nao executado); {len(linhas)} linhas seriam enviadas")
        return 0
    job.result()
    return job.num_dml_affected_rows or 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--simular", action="store_true", help="faz tudo, menos gravar (MERGE em dry_run)")
    args = parser.parse_args()

    manipulador = logging.StreamHandler(sys.stdout)
    manipulador.setFormatter(FormatoCloudLogging())
    logging.basicConfig(level=logging.INFO, handlers=[manipulador])

    hoje = datetime.now(ZoneInfo(FUSO)).date()
    cliente = bigquery.Client(project=PROJETO)
    estado_atual = {r.estado: r for r in cliente.query(SQL_ESTADO).result()}
    log.info(f"inicio: hoje={hoje} tabela={TABELA} simular={args.simular}")

    linhas, erros = [], []
    for estado, (cidade, lat, lon) in CIDADES.items():
        try:
            if estado not in estado_atual or estado_atual[estado].ultimo_observado is None:
                raise RuntimeError("estado sem nenhum observado na bronze -- carga historica nao e papel deste job")
            ultimo_obs = estado_atual[estado].ultimo_observado
            datas_previsao = set(estado_atual[estado].datas_previsao)

            # observado entra na lista antes da previsao: falha na previsao nao descarta o observado
            observado = buscar_observado(lat, lon, ultimo_obs + timedelta(days=1), hoje)
            novo_ultimo_obs = max([ultimo_obs, *observado])
            linhas += [montar_linha(estado, cidade, d, v, FONTE_OBSERVADO, hoje) for d, v in observado.items()]
            viraram_observado = sum(d in datas_previsao for d in observado)
            log.info(
                f"{estado} {cidade}: ultimo_observado {ultimo_obs} -> {novo_ultimo_obs}; "
                f"observado: {viraram_observado} previsao->observado, {len(observado) - viraram_observado} novos"
            )

            modelo, previsao = buscar_previsao(lat, lon, novo_ultimo_obs + timedelta(days=1), hoje)
            linhas += [montar_linha(estado, cidade, d, v, f"{PREFIXO_PREVISAO}/{modelo}", hoje)
                       for d, v in previsao.items()]
            log.info(f"{estado} {cidade}: previsao ({modelo}): {len(previsao)} dias, "
                     f"{min(previsao)} a {max(previsao)}")
        except Exception as erro:  # noqa: BLE001 -- registra e segue para a proxima cidade
            log.error(f"{estado} {cidade}: {erro}")
            erros.append(estado)

    if linhas:
        afetadas = gravar(cliente, linhas, args.simular)
        if not args.simular:
            log.info(f"MERGE: {len(linhas)} linhas enviadas, {afetadas} afetadas")
    if erros:
        log.error(f"fim com falha em {len(erros)} cidade(s): {', '.join(erros)}")
        return 1
    log.info(f"fim: ok nas {len(CIDADES)} cidades")
    return 0


if __name__ == "__main__":
    sys.exit(main())
