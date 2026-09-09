-- Bloco 10: treino do modelo de regressão linear sobre dados_treino.
-- Entrada: produto, classe, mes, dia_semana. Nenhum preço entra como
-- feature — o modelo responde a partir de identificação e data apenas.
-- Split temporal: treino usa só data <= 2025-12-31; a partição de teste
-- (data >= 2026-01-01) fica de fora e é avaliada em 05_baseline_avaliacao.sql.
--
-- CREATE OR REPLACE MODEL: idempotente, reexecutar substitui o modelo anterior.

CREATE OR REPLACE MODEL `pdm-ceasa.baseline.modelo_regressao_linear`
OPTIONS (
  model_type = 'LINEAR_REG',
  input_label_cols = ['alvo']
) AS
SELECT
  produto,
  classe,
  mes,
  dia_semana,
  alvo
FROM `pdm-ceasa.baseline.dados_treino`
WHERE data <= '2025-12-31';
