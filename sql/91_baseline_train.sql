-- Baseline: treino de regressão linear global sobre as features cruas.
-- Split temporal, nunca aleatório: treino usa apenas data <= 2025-12-31.
-- A partição de teste (data >= 2026-01-01) fica fora do treino e é avaliada
-- separadamente em 92_baseline_eval.sql.
--
-- CREATE OR REPLACE MODEL: idempotente, reexecutar substitui o modelo anterior.

CREATE OR REPLACE MODEL `pdm-ceasa.baseline.modelo_preco`
OPTIONS (
  model_type = 'LINEAR_REG',
  input_label_cols = ['alvo']
) AS
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
WHERE data <= '2025-12-31';
