-- Bloco 10: treino do modelo de árvore boosted sobre dados_treino.
-- Entrada idêntica ao modelo linear: produto, classe, mes, dia_semana.
-- Nenhum preço entra como feature. Mesmo split temporal (treino <= 2025-12-31).
--
-- CREATE OR REPLACE MODEL: idempotente, reexecutar substitui o modelo anterior.

CREATE OR REPLACE MODEL `pdm-ceasa.baseline.modelo_regressao_arvore`
OPTIONS (
  model_type = 'BOOSTED_TREE_REGRESSOR',
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
