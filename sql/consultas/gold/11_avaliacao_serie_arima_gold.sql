-- Avaliacao dos modelos gold.modelo_serie_arima_semanal e
-- gold.modelo_serie_arima_mensal via ML.ARIMA_EVALUATE.
-- Faz: reporta, por serie (produto, classe), a ordem (p,d,q) escolhida pelo
-- AUTO_ARIMA, o AIC, sazonalidade detectada -- item de atencao obrigatorio,
-- porque analitica_semanal/analitica_mensal tem buracos reais por
-- construcao (vaos medios sem interpolar, grade nao continua) e a
-- frequencia detectada pode divergir do esperado (semanal/mensal).
-- Nao faz: nao persiste nenhuma tabela, nao ha ML.EVALUATE com particao de
-- teste -- decisao registrada de nao criar particao para o ARIMA.
--
-- Esperado: uma linha por serie (produto, classe) que o AUTO_ARIMA
-- conseguiu ajustar, ate 210 pares por granularidade. Series que o ARIMA
-- nao conseguiu modelar sao achado, quantificadas na segunda consulta de
-- cada bloco.

-- Semanal: ordem, AIC e sazonalidade por serie
SELECT
  'semanal' AS granularidade,
  produto, classe,
  non_seasonal_p, non_seasonal_d, non_seasonal_q,
  has_drift, has_holiday_effect, has_spikes_and_dips, has_step_changes,
  seasonal_periods, aic, variance, error_message
FROM ML.ARIMA_EVALUATE(MODEL `pdm-ceasa.gold.modelo_serie_arima_semanal`)
ORDER BY produto, classe;

-- Semanal: series na fonte vs. series avaliadas (com e sem erro).
-- error_message vem como string vazia quando nao ha erro, nao NULL --
-- confirmado empiricamente (COUNTIF(error_message IS NOT NULL) contava
-- string vazia como erro). NULLIF trata os dois casos corretamente.
WITH series_fonte AS (
  SELECT COUNT(DISTINCT CONCAT(produto, '|', CAST(classe AS STRING))) AS total_series
  FROM `pdm-ceasa.gold.analitica_semanal`
),
series_avaliadas AS (
  SELECT
    COUNT(*) AS total_avaliadas,
    COUNTIF(NULLIF(error_message, '') IS NOT NULL) AS com_erro,
    COUNTIF(NULLIF(error_message, '') IS NULL) AS sem_erro
  FROM ML.ARIMA_EVALUATE(MODEL `pdm-ceasa.gold.modelo_serie_arima_semanal`)
)
SELECT
  'semanal' AS granularidade,
  total_series, total_avaliadas,
  total_series - total_avaliadas AS series_nao_avaliadas,
  com_erro, sem_erro
FROM series_fonte, series_avaliadas;

-- Mensal: ordem, AIC e sazonalidade por serie
SELECT
  'mensal' AS granularidade,
  produto, classe,
  non_seasonal_p, non_seasonal_d, non_seasonal_q,
  has_drift, has_holiday_effect, has_spikes_and_dips, has_step_changes,
  seasonal_periods, aic, variance, error_message
FROM ML.ARIMA_EVALUATE(MODEL `pdm-ceasa.gold.modelo_serie_arima_mensal`)
ORDER BY produto, classe;

-- Mensal: series na fonte vs. series avaliadas (com e sem erro)
WITH series_fonte AS (
  SELECT COUNT(DISTINCT CONCAT(produto, '|', CAST(classe AS STRING))) AS total_series
  FROM `pdm-ceasa.gold.analitica_mensal`
),
series_avaliadas AS (
  SELECT
    COUNT(*) AS total_avaliadas,
    COUNTIF(NULLIF(error_message, '') IS NOT NULL) AS com_erro,
    COUNTIF(NULLIF(error_message, '') IS NULL) AS sem_erro
  FROM ML.ARIMA_EVALUATE(MODEL `pdm-ceasa.gold.modelo_serie_arima_mensal`)
)
SELECT
  'mensal' AS granularidade,
  total_series, total_avaliadas,
  total_series - total_avaliadas AS series_nao_avaliadas,
  com_erro, sem_erro
FROM series_fonte, series_avaliadas;
