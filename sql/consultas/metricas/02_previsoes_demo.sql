-- Previsoes dos 6 modelos (baseline/bronze e silver) para as 3 datas do
-- recorte de demo (2026-09-01, 2026-09-03, 2026-09-04), num formato comum
-- (camada, modelo, produto, classe, data, preco_previsto) para casamento em
-- Python contra o valor observado do recorte.
--
-- Faz: ML.PREDICT (regressao linear e arvore, das duas camadas) e
-- ML.FORECAST (ARIMA, das duas camadas), todos sobre modelo ja treinado.
-- Baseline (bronze): vetor de entrada = produto (RAW, mesma grafia da
-- Bronze), classe, mes, dia_semana -- identico ao treino, sem preco. Como
-- essas features nao dependem de cotacao no dia, sao construidas por
-- CROSS JOIN de (produto, classe) distintos da bronze com as 3 datas.
-- Silver: vetor de entrada = produto (normalizado), classe, grupo, ano,
-- mes, dia_semana, lag_7/14/30/365/730 -- mesma regra de
-- sql/construir_tabelas/silver/08_dados_treino.sql, mas ancorada em cada
-- uma das 3 datas de demo (nao em "data" da propria tabela), porque
-- silver.dados_treino termina em 2026-08-21 e nao cobre essas datas. Os
-- lags vem de silver.cotacoes (unica fonte com o historico necessario).
-- ARIMA (ambas as camadas): ML.FORECAST com STRUCT(horizon) explicito --
-- sem isso o horizonte default da funcao e 3, nao o do treino (achado ja
-- registrado em docs/modelos/modelo_serie_arima.md e no script
-- sql/consultas/silver/14_forecast_serie_arima.sql). Baseline treinou com
-- horizon=4 e alcanca no maximo 2026-09-01 -- se as linhas de 09-03 e 09-04
-- nao aparecerem para bronze/serie_arima, e o esperado, nao erro desta
-- consulta.
--
-- Nao faz: nao contem CREATE MODEL nem CREATE OR REPLACE MODEL. Nao grava
-- nenhuma tabela -- consulta pura, o resultado e consumido por
-- scripts/metricas_demo.py via "bq query ... --format=csv". Nao le nem
-- referencia o recorte local (~/Dropbox/PDM/recorte/cotacoes_recorte_demo.csv)
-- -- esse arquivo so entra no lado Python.

WITH datas AS (
  SELECT data FROM UNNEST([DATE '2026-09-01', DATE '2026-09-03', DATE '2026-09-04']) AS data
),

bronze_pares AS (
  SELECT DISTINCT produto, classe
  FROM `pdm-ceasa.bronze.cotacoes`
),

bronze_entrada AS (
  SELECT
    p.produto,
    p.classe,
    d.data,
    EXTRACT(MONTH FROM d.data) AS mes,
    EXTRACT(DAYOFWEEK FROM d.data) AS dia_semana
  FROM bronze_pares AS p
  CROSS JOIN datas AS d
),

silver_serie AS (
  SELECT
    produto,
    classe,
    ANY_VALUE(grupo) AS grupo,
    ARRAY_AGG(STRUCT(data AS data, preco_comum AS preco_comum) ORDER BY data) AS pregoes
  FROM `pdm-ceasa.silver.cotacoes`
  GROUP BY produto, classe
),

silver_entrada AS (
  SELECT
    s.produto,
    s.classe,
    s.grupo,
    d.data,
    EXTRACT(YEAR FROM d.data) AS ano,
    EXTRACT(MONTH FROM d.data) AS mes,
    EXTRACT(DAYOFWEEK FROM d.data) AS dia_semana,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(d.data, INTERVAL 7 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_7,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(d.data, INTERVAL 14 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_14,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(d.data, INTERVAL 30 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_30,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(d.data, INTERVAL 365 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_365,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(d.data, INTERVAL 730 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_730
  FROM silver_serie AS s
  CROSS JOIN datas AS d
),

bronze_linear AS (
  SELECT
    'bronze' AS camada, 'regressao_linear' AS modelo,
    produto, classe, data, predicted_alvo AS preco_previsto
  FROM ML.PREDICT(
    MODEL `pdm-ceasa.baseline.modelo_regressao_linear`,
    (SELECT * FROM bronze_entrada)
  )
),

bronze_arvore AS (
  SELECT
    'bronze' AS camada, 'regressao_arvore' AS modelo,
    produto, classe, data, predicted_alvo AS preco_previsto
  FROM ML.PREDICT(
    MODEL `pdm-ceasa.baseline.modelo_regressao_arvore`,
    (SELECT * FROM bronze_entrada)
  )
),

bronze_arima AS (
  SELECT
    'bronze' AS camada, 'serie_arima' AS modelo,
    SPLIT(serie_id, '|')[OFFSET(0)] AS produto,
    CAST(SPLIT(serie_id, '|')[OFFSET(1)] AS INT64) AS classe,
    DATE(forecast_timestamp) AS data,
    forecast_value AS preco_previsto
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.baseline.modelo_serie_arima`,
    STRUCT(4 AS horizon)
  )
  WHERE DATE(forecast_timestamp) IN (DATE '2026-09-01', DATE '2026-09-03', DATE '2026-09-04')
),

silver_linear AS (
  SELECT
    'silver' AS camada, 'regressao_linear' AS modelo,
    produto, classe, data, predicted_alvo AS preco_previsto
  FROM ML.PREDICT(
    MODEL `pdm-ceasa.silver.modelo_regressao_linear`,
    (SELECT * FROM silver_entrada)
  )
),

silver_arvore AS (
  SELECT
    'silver' AS camada, 'regressao_arvore' AS modelo,
    produto, classe, data, predicted_alvo AS preco_previsto
  FROM ML.PREDICT(
    MODEL `pdm-ceasa.silver.modelo_regressao_arvore`,
    (SELECT * FROM silver_entrada)
  )
),

silver_arima AS (
  SELECT
    'silver' AS camada, 'serie_arima' AS modelo,
    produto, classe,
    DATE(forecast_timestamp) AS data,
    forecast_value AS preco_previsto
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.silver.modelo_serie_arima`,
    STRUCT(60 AS horizon)
  )
  WHERE DATE(forecast_timestamp) IN (DATE '2026-09-01', DATE '2026-09-03', DATE '2026-09-04')
)

SELECT * FROM bronze_linear
UNION ALL SELECT * FROM bronze_arvore
UNION ALL SELECT * FROM bronze_arima
UNION ALL SELECT * FROM silver_linear
UNION ALL SELECT * FROM silver_arvore
UNION ALL SELECT * FROM silver_arima
ORDER BY camada, modelo, produto, classe, data;
