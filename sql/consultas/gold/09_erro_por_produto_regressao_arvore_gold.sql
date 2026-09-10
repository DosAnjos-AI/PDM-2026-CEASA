-- Erro do modelo gold.modelo_regressao_arvore_semanal e
-- gold.modelo_regressao_arvore_mensal quebrado por produto -- mesmo padrao
-- de sql/consultas/gold/07_erro_por_produto_regressao_linear_gold.sql.
-- Nao faz: nao persiste nenhuma tabela, nao filtra nenhum produto.

-- Semanal
SELECT
  'semanal' AS granularidade,
  produto,
  COUNT(*) AS linhas_teste,
  AVG(ABS(alvo - predicted_alvo)) AS mae,
  AVG(ABS(alvo - predicted_alvo) / NULLIF(alvo, 0)) AS erro_percentual_medio
FROM ML.PREDICT(
  MODEL `pdm-ceasa.gold.modelo_regressao_arvore_semanal`,
  (
    SELECT
      produto, classe, grupo, isoyear, isoweek,
      lag_1s, lag_2s, lag_4s, lag_52s, lag_104s, alvo
    FROM `pdm-ceasa.gold.treino_semanal`
    WHERE data_inicio_semana > '2025-12-31'
  )
)
GROUP BY produto
ORDER BY mae DESC;

-- Mensal
SELECT
  'mensal' AS granularidade,
  produto,
  COUNT(*) AS linhas_teste,
  AVG(ABS(alvo - predicted_alvo)) AS mae,
  AVG(ABS(alvo - predicted_alvo) / NULLIF(alvo, 0)) AS erro_percentual_medio
FROM ML.PREDICT(
  MODEL `pdm-ceasa.gold.modelo_regressao_arvore_mensal`,
  (
    SELECT
      produto, classe, grupo, ano, mes,
      lag_1m, lag_12m, lag_24m, alvo
    FROM `pdm-ceasa.gold.treino_mensal`
    WHERE DATE(ano, mes, 1) > '2025-12-31'
  )
)
GROUP BY produto
ORDER BY mae DESC;
