-- Erro do modelo silver.modelo_regressao_arvore quebrado por produto, na
-- particao de teste (data >= 2026-01-01).
-- Faz: ML.PREDICT sobre a particao de teste, agrupado por produto: MAE e
-- erro percentual medio (|erro| / alvo observado, alvo=0 vira NULL e sai
-- da media via NULLIF).
-- Nao faz: nao persiste nenhuma tabela, nao filtra nenhum produto.
--
-- Esperado: 141 produtos, ou menos se algum nao tiver linha na particao de
-- teste -- se isso acontecer, declarar quais faltaram.

SELECT
  produto,
  COUNT(*) AS linhas_teste,
  AVG(ABS(alvo - predicted_alvo)) AS mae,
  AVG(ABS(alvo - predicted_alvo) / NULLIF(alvo, 0)) AS erro_percentual_medio
FROM ML.PREDICT(
  MODEL `pdm-ceasa.silver.modelo_regressao_arvore`,
  (
    SELECT
      produto, classe, grupo, ano, mes, dia_semana,
      lag_7, lag_14, lag_30, lag_365, lag_730, alvo
    FROM `pdm-ceasa.silver.dados_treino`
    WHERE data >= '2026-01-01'
  )
)
GROUP BY produto
ORDER BY mae DESC;
