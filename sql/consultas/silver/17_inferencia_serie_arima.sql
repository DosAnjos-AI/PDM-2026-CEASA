-- Inferencia (previsao) do modelo silver.modelo_serie_arima (ARIMA_PLUS,
-- horizon=60, treinado sobre silver.cotacoes --
-- sql/modelo/silver/03_modelo_serie_arima.sql). ML.FORECAST apenas le o
-- modelo ja treinado -- nao ha CREATE MODEL nesta consulta, nenhuma tabela
-- e criada ou alterada.
--
-- ARIMA nao recebe vetor: projeta a partir da ULTIMA observacao real da
-- propria serie (produto, classe), nao da data-base do usuario (que so
-- existe nos modelos de regressao). "data_base_usada" aqui e essa ultima
-- observacao real, para rastreabilidade.
-- horizon=60 repete exatamente o valor do treino -- ML.FORECAST nao herda o
-- horizon do treino (default proprio = 3 sem STRUCT explicito, achado ja
-- registrado em sql/consultas/silver/14_forecast_serie_arima.sql) e nao
-- aceita valor maior que o treinado.
-- Se p_data_alvo cair fora do alcance do horizonte previsto para essa
-- serie, devolve previsao NULL com mensagem explicita, nunca o passo mais
-- proximo silenciosamente.
--
-- Nao faz: nao cria, nao altera nem substitui nenhuma tabela ou modelo.
--
-- Para trocar produto/classe/data prevista, editar so o bloco DECLARE
-- abaixo -- nenhum outro trecho precisa mudar.

-- ===================== UNICO PONTO DE EDICAO ======================
DECLARE p_produto   STRING DEFAULT 'tomate_saladete';
DECLARE p_classe    INT64  DEFAULT 1;
DECLARE p_data_alvo DATE   DEFAULT '2026-09-04';
-- ====================================================================

WITH ultima_observacao AS (
  SELECT MAX(data) AS data_base_usada
  FROM `pdm-ceasa.silver.cotacoes`
  WHERE produto = p_produto AND classe = p_classe
),
forecast AS (
  SELECT *
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.silver.modelo_serie_arima`,
    STRUCT(60 AS horizon, 0.95 AS confidence_level)
  )
  WHERE produto = p_produto AND classe = p_classe
),
alcance AS (
  SELECT MAX(DATE(forecast_timestamp)) AS data_final_serie
  FROM forecast
)
SELECT
  'silver.modelo_serie_arima' AS modelo,
  p_produto AS produto,
  p_classe AS classe,
  p_data_alvo AS data_alvo,
  u.data_base_usada,
  f.forecast_value AS previsao,
  f.prediction_interval_lower_bound,
  f.prediction_interval_upper_bound,
  CASE
    WHEN u.data_base_usada IS NULL
      THEN CONCAT('Produto "', p_produto, '" classe ', CAST(p_classe AS STRING), ' nao encontrado em silver.cotacoes.')
    WHEN f.forecast_value IS NULL THEN CONCAT(
      'Fora do alcance do horizonte treinado (horizon=60) para esta serie. ',
      'Ultima observacao real: ', CAST(u.data_base_usada AS STRING),
      '; ultima data prevista pelo modelo: ', CAST(a.data_final_serie AS STRING), '.'
    )
    ELSE NULL
  END AS observacao
FROM ultima_observacao AS u
CROSS JOIN alcance AS a
LEFT JOIN forecast AS f
  ON DATE(f.forecast_timestamp) = p_data_alvo;
