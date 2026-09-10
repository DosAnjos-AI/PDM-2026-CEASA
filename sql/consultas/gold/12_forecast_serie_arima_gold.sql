-- Previsao dos modelos gold.modelo_serie_arima_semanal (horizon=90,
-- treinado) e gold.modelo_serie_arima_mensal (horizon=24, treinado) via
-- ML.FORECAST, com STRUCT(horizon) explicito -- sem isso o horizonte
-- default da funcao e 3, nao o do treino (achado ja registrado na Silver:
-- sql/consultas/silver/14_forecast_serie_arima.sql). horizon aqui replica
-- exatamente o valor do treino; ML.FORECAST nao aceita valor maior.
-- Faz: lista a data final realmente alcancada por serie, quantas series
-- cobrem 2026-09-04, e quantas tem previsao alem de 2027 (item de atencao
-- obrigatorio -- na Silver isso ja produziu uma serie extrapolando ate
-- 2072-05-14 por passo inferido em anos).
-- Nao faz: nao persiste nenhuma tabela, nao filtra nenhum produto. Nao ha
-- ML.EVALUATE com particao de teste para o ARIMA -- decisao ja registrada,
-- nao inventada aqui.

-- Semanal: data final por serie e cobertura de 2026-09-04
WITH forecast_semanal AS (
  SELECT
    produto, classe,
    MAX(DATE(forecast_timestamp)) AS data_final_serie
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.gold.modelo_serie_arima_semanal`,
    STRUCT(90 AS horizon, 0.95 AS confidence_level)
  )
  GROUP BY produto, classe
)
SELECT
  'semanal' AS granularidade,
  COUNT(*) AS total_series,
  MIN(data_final_serie) AS pior_caso_data_final,
  MAX(data_final_serie) AS melhor_caso_data_final,
  COUNTIF(data_final_serie >= '2026-09-04') AS series_cobrem_09_04,
  COUNTIF(data_final_serie < '2026-09-04') AS series_abaixo_de_09_04,
  COUNTIF(data_final_serie > '2027-12-31') AS series_alem_de_2027
FROM forecast_semanal;

-- Mensal: data final por serie e cobertura de 2026-09-04 (mes de setembro)
WITH forecast_mensal AS (
  SELECT
    produto, classe,
    MAX(DATE(forecast_timestamp)) AS data_final_serie
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.gold.modelo_serie_arima_mensal`,
    STRUCT(24 AS horizon, 0.95 AS confidence_level)
  )
  GROUP BY produto, classe
)
SELECT
  'mensal' AS granularidade,
  COUNT(*) AS total_series,
  MIN(data_final_serie) AS pior_caso_data_final,
  MAX(data_final_serie) AS melhor_caso_data_final,
  COUNTIF(data_final_serie >= '2026-09-01') AS series_cobrem_setembro_2026,
  COUNTIF(data_final_serie < '2026-09-01') AS series_abaixo_de_setembro_2026,
  COUNTIF(data_final_serie > '2027-12-31') AS series_alem_de_2027
FROM forecast_mensal;
