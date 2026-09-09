-- Bloco 10: avaliação dos três modelos, métricas gravadas em formato longo
-- (modelo, metrica, valor) numa única tabela, para acomodar métricas de
-- naturezas diferentes (regressão vs. série temporal) sob uma coluna comum
-- que identifica o modelo.
--
-- Linear e árvore: ML.EVALUATE estritamente sobre a partição de teste
-- (data >= 2026-01-01), nunca vista no treino.
--
-- ARIMA: não existe tabela de teste tabular para ML.EVALUATE nesse formato
-- (é um modelo de série, não um regressor de linha). A comparação é feita
-- manualmente: para cada série, pega-se a previsão do 7º passo do horizonte
-- (ML.FORECAST com horizon=7, ponto mais distante projetado a partir do fim
-- do treino) e compara com o alvo real já calculado em dados_treino para a
-- última linha de treino da série — o preço no pregão mais próximo seguinte
-- a 7 dias após o fim do treino. É a mesma definição de alvo usada nos
-- outros dois modelos, o que torna a comparação equivalente.
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.baseline.metricas` AS
WITH eval_linear AS (
  SELECT *
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.baseline.modelo_regressao_linear`,
    (
      SELECT produto, classe, mes, dia_semana, alvo
      FROM `pdm-ceasa.baseline.dados_treino`
      WHERE data >= '2026-01-01'
    )
  )
),
eval_arvore AS (
  SELECT *
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.baseline.modelo_regressao_arvore`,
    (
      SELECT produto, classe, mes, dia_semana, alvo
      FROM `pdm-ceasa.baseline.dados_treino`
      WHERE data >= '2026-01-01'
    )
  )
),
regressao_long AS (
  SELECT 'modelo_regressao_linear' AS modelo, 'mean_absolute_error' AS metrica, mean_absolute_error AS valor FROM eval_linear
  UNION ALL SELECT 'modelo_regressao_linear', 'mean_squared_error', mean_squared_error FROM eval_linear
  UNION ALL SELECT 'modelo_regressao_linear', 'r2_score', r2_score FROM eval_linear
  UNION ALL SELECT 'modelo_regressao_linear', 'explained_variance', explained_variance FROM eval_linear
  UNION ALL SELECT 'modelo_regressao_arvore', 'mean_absolute_error', mean_absolute_error FROM eval_arvore
  UNION ALL SELECT 'modelo_regressao_arvore', 'mean_squared_error', mean_squared_error FROM eval_arvore
  UNION ALL SELECT 'modelo_regressao_arvore', 'r2_score', r2_score FROM eval_arvore
  UNION ALL SELECT 'modelo_regressao_arvore', 'explained_variance', explained_variance FROM eval_arvore
),
ultima_linha_treino AS (
  SELECT
    CONCAT(produto, '|', CAST(classe AS STRING)) AS serie_id,
    alvo AS valor_real
  FROM `pdm-ceasa.baseline.dados_treino`
  WHERE data <= '2025-12-31'
  QUALIFY ROW_NUMBER() OVER (PARTITION BY produto, classe ORDER BY data DESC) = 1
),
previsao_arima AS (
  SELECT
    serie_id,
    forecast_value AS valor_previsto
  FROM ML.FORECAST(MODEL `pdm-ceasa.baseline.modelo_serie_arima`, STRUCT(7 AS horizon))
  QUALIFY ROW_NUMBER() OVER (PARTITION BY serie_id ORDER BY forecast_timestamp DESC) = 1
),
comparacao_arima AS (
  SELECT u.valor_real, p.valor_previsto
  FROM ultima_linha_treino u
  JOIN previsao_arima p USING (serie_id)
  WHERE u.valor_real IS NOT NULL
),
arima_long AS (
  SELECT 'modelo_serie_arima' AS modelo, 'mean_absolute_error' AS metrica, AVG(ABS(valor_real - valor_previsto)) AS valor FROM comparacao_arima
  UNION ALL
  SELECT 'modelo_serie_arima', 'root_mean_squared_error', SQRT(AVG(POW(valor_real - valor_previsto, 2))) FROM comparacao_arima
  UNION ALL
  SELECT 'modelo_serie_arima', 'n_series_avaliadas', COUNT(*) FROM comparacao_arima
)
SELECT * FROM regressao_long
UNION ALL
SELECT * FROM arima_long;

SELECT * FROM `pdm-ceasa.baseline.metricas` ORDER BY modelo, metrica;
