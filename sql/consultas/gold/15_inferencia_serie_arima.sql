-- Inferencia (previsao) dos modelos gold.modelo_serie_arima_semanal
-- (horizon=90) e gold.modelo_serie_arima_mensal (horizon=24), treinados
-- sobre gold.analitica_semanal e gold.analitica_mensal --
-- sql/modelo/gold/05_modelo_serie_arima_semanal.sql e
-- 06_modelo_serie_arima_mensal.sql. ML.FORECAST apenas le os modelos ja
-- treinados -- nao ha CREATE MODEL nesta consulta, nenhuma tabela e criada
-- ou alterada.
--
-- ARIMA nao recebe vetor: projeta a partir da ULTIMA observacao real da
-- propria serie (produto, classe), nao da data-base do usuario (que so
-- existe nos modelos de regressao). "data_base_usada" aqui e essa ultima
-- observacao real, para rastreabilidade.
-- horizon repete exatamente o valor do treino em cada bloco (90 semanal,
-- 24 mensal) -- ML.FORECAST nao herda o horizon do treino (default proprio
-- = 3 sem STRUCT explicito, achado ja registrado na Silver) e nao aceita
-- valor maior que o treinado.
-- Se p_data_alvo cair fora do alcance do horizonte previsto para essa
-- serie, devolve previsao NULL com mensagem explicita, nunca o passo mais
-- proximo silenciosamente.
--
-- IMPORTANTE: "previsao" aqui e MEDIA DE PRECO DO PERIODO (semana/mes),
-- nao preco de um dia -- coluna unidade_previsao deixa isso explicito.
--
-- Nao faz: nao cria, nao altera nem substitui nenhuma tabela ou modelo.
--
-- Para trocar produto/classe/data prevista, editar so o bloco DECLARE
-- abaixo -- nenhum outro trecho precisa mudar. O mesmo DECLARE vale para os
-- dois blocos (semanal e mensal) abaixo. Regra do BigQuery Scripting: todo
-- DECLARE tem que vir antes de qualquer SELECT no script -- por isso as
-- variaveis auxiliares de ambos os blocos estao todas aqui no topo.

-- ===================== UNICO PONTO DE EDICAO ======================
DECLARE p_produto   STRING DEFAULT 'tomate_saladete';
DECLARE p_classe    INT64  DEFAULT 1;
DECLARE p_data_alvo DATE   DEFAULT '2026-09-04';
-- ====================================================================

-- Periodo alvo para casar o forecast semanal: inicio da semana ISO que
-- contem p_data_alvo (mesma convencao de data_inicio_semana do treino).
DECLARE p_semana_alvo DATE DEFAULT DATE_TRUNC(p_data_alvo, ISOWEEK);
-- Periodo alvo para casar o forecast mensal: primeiro dia do mes que
-- contem p_data_alvo (mesma convencao de data_inicio_mes do treino).
DECLARE p_mes_alvo DATE DEFAULT DATE_TRUNC(p_data_alvo, MONTH);

-- ===================================== SEMANAL =====================================
WITH ultima_observacao AS (
  SELECT MAX(data_inicio_semana) AS data_base_usada
  FROM `pdm-ceasa.gold.analitica_semanal`
  WHERE produto = p_produto AND classe = p_classe
),
forecast AS (
  SELECT *
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.gold.modelo_serie_arima_semanal`,
    STRUCT(90 AS horizon, 0.95 AS confidence_level)
  )
  WHERE produto = p_produto AND classe = p_classe
),
alcance AS (
  SELECT MAX(DATE(forecast_timestamp)) AS data_final_serie
  FROM forecast
)
SELECT
  'gold.modelo_serie_arima_semanal' AS modelo,
  'semanal' AS granularidade,
  'media_semanal' AS unidade_previsao,
  p_produto AS produto,
  p_classe AS classe,
  p_data_alvo AS data_alvo,
  u.data_base_usada,
  f.forecast_value AS previsao,
  f.prediction_interval_lower_bound,
  f.prediction_interval_upper_bound,
  CASE
    WHEN u.data_base_usada IS NULL
      THEN CONCAT('Produto "', p_produto, '" classe ', CAST(p_classe AS STRING), ' nao encontrado em gold.analitica_semanal.')
    WHEN f.forecast_value IS NULL THEN CONCAT(
      'Fora do alcance do horizonte treinado (horizon=90) para esta serie. ',
      'Ultima observacao real: ', CAST(u.data_base_usada AS STRING),
      '; ultima data prevista pelo modelo: ', CAST(a.data_final_serie AS STRING), '.'
    )
    ELSE NULL
  END AS observacao
FROM ultima_observacao AS u
CROSS JOIN alcance AS a
LEFT JOIN forecast AS f
  ON DATE(f.forecast_timestamp) = p_semana_alvo;

-- ===================================== MENSAL =====================================
WITH ultima_observacao AS (
  SELECT MAX(DATE(ano, mes, 1)) AS data_base_usada
  FROM `pdm-ceasa.gold.analitica_mensal`
  WHERE produto = p_produto AND classe = p_classe
),
forecast AS (
  SELECT *
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.gold.modelo_serie_arima_mensal`,
    STRUCT(24 AS horizon, 0.95 AS confidence_level)
  )
  WHERE produto = p_produto AND classe = p_classe
),
alcance AS (
  SELECT MAX(DATE(forecast_timestamp)) AS data_final_serie
  FROM forecast
)
SELECT
  'gold.modelo_serie_arima_mensal' AS modelo,
  'mensal' AS granularidade,
  'media_mensal' AS unidade_previsao,
  p_produto AS produto,
  p_classe AS classe,
  p_data_alvo AS data_alvo,
  u.data_base_usada,
  f.forecast_value AS previsao,
  f.prediction_interval_lower_bound,
  f.prediction_interval_upper_bound,
  CASE
    WHEN u.data_base_usada IS NULL
      THEN CONCAT('Produto "', p_produto, '" classe ', CAST(p_classe AS STRING), ' nao encontrado em gold.analitica_mensal.')
    WHEN f.forecast_value IS NULL THEN CONCAT(
      'Fora do alcance do horizonte treinado (horizon=24) para esta serie. ',
      'Ultima observacao real: ', CAST(u.data_base_usada AS STRING),
      '; ultima data prevista pelo modelo: ', CAST(a.data_final_serie AS STRING), '.'
    )
    ELSE NULL
  END AS observacao
FROM ultima_observacao AS u
CROSS JOIN alcance AS a
LEFT JOIN forecast AS f
  ON DATE(f.forecast_timestamp) = p_mes_alvo;
