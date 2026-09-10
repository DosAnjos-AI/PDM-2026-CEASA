-- Erro do modelo gold.modelo_regressao_linear_semanal e
-- gold.modelo_regressao_linear_mensal quebrado por produto, na respectiva
-- particao de teste.
-- Faz: ML.PREDICT sobre a particao de teste, agrupado por produto: MAE e
-- erro percentual medio (|erro| / alvo observado, alvo=0 vira NULL e sai da
-- media via NULLIF).
-- Nao faz: nao persiste nenhuma tabela, nao filtra nenhum produto.
--
-- Esperado: ate 141 produtos por granularidade, ou menos se algum nao tiver
-- linha na particao de teste -- se isso acontecer, declarar quais
-- faltaram.

-- Semanal
SELECT
  'semanal' AS granularidade,
  produto,
  COUNT(*) AS linhas_teste,
  AVG(ABS(alvo - predicted_alvo)) AS mae,
  AVG(ABS(alvo - predicted_alvo) / NULLIF(alvo, 0)) AS erro_percentual_medio
FROM ML.PREDICT(
  MODEL `pdm-ceasa.gold.modelo_regressao_linear_semanal`,
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
  MODEL `pdm-ceasa.gold.modelo_regressao_linear_mensal`,
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
