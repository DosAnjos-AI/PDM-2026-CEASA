-- Bloco 10/11: avaliação dos três modelos, métricas gravadas em formato longo
-- (modelo, metrica, valor) numa única tabela, para acomodar métricas de
-- naturezas diferentes (regressão vs. série temporal) sob uma coluna comum
-- que identifica o modelo.
--
-- Linear e árvore: ML.EVALUATE estritamente sobre a partição de teste
-- (data >= 2026-01-01), nunca vista no treino. Inalterado desde o Bloco 10.
--
-- ARIMA (Bloco 11): decisão registrada -- o modelo passou a treinar com a
-- série inteira, sem partição de teste, porque vale pela previsão ao vivo
-- na apresentação (comparada depois contra o recorte de 4 datas da demo),
-- não por métrica de teste. Sem partição de teste não há o que avaliar
-- aqui: a linha do ARIMA na tabela é marcada explicitamente como não
-- aplicável (valor NULL), em vez de inventar uma métrica sobre dado visto
-- no treino.
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
arima_long AS (
  SELECT 'modelo_serie_arima' AS modelo, 'sem_particao_teste' AS metrica, CAST(NULL AS FLOAT64) AS valor
)
SELECT * FROM regressao_long
UNION ALL
SELECT * FROM arima_long;

SELECT * FROM `pdm-ceasa.baseline.metricas` ORDER BY modelo, metrica;
