-- Baseline: avaliação do modelo estritamente na partição de teste (data >= 2026-01-01),
-- nunca vista no treino. Métricas gravadas em tabela para consulta posterior.
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.baseline.metricas_eval` AS
SELECT *
FROM ML.EVALUATE(
  MODEL `pdm-ceasa.baseline.modelo_preco`,
  (
    SELECT
      produto,
      classe,
      mes,
      dia_semana,
      lag_1,
      lag_2,
      lag_3,
      lag_4,
      lag_5,
      alvo
    FROM `pdm-ceasa.baseline.features`
    WHERE data >= '2026-01-01'
  )
);

SELECT * FROM `pdm-ceasa.baseline.metricas_eval`;
