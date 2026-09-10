-- Avaliacao do modelo silver.modelo_regressao_linear na particao de teste
-- (data >= 2026-01-01, nunca vista no treino) e comparacao lado a lado com
-- o baseline ja treinado sobre a bronze crua (pdm-ceasa.baseline.metricas).
-- Faz: ML.EVALUATE + RMSE calculado (RMSE nao e retornado nativamente por
-- ML.EVALUATE); segunda consulta junta essas metricas com as do baseline.
-- Nao faz: nao persiste nenhuma tabela.
--
-- Ressalva obrigatoria: esta comparacao NAO isola o efeito da limpeza.
-- A Silver tem limpeza E engenharia de features (os 5 lags); o baseline
-- nao tem nenhuma das duas. A diferenca entre as duas linhas mede os dois
-- efeitos somados, nao um isolado do outro. Decisao tomada, nao defeito --
-- mas precisa estar dita no relatorio.

SELECT
  r2_score,
  mean_absolute_error,
  mean_squared_error,
  SQRT(mean_squared_error) AS rmse
FROM ML.EVALUATE(
  MODEL `pdm-ceasa.silver.modelo_regressao_linear`,
  (
    SELECT
      produto, classe, grupo, ano, mes, dia_semana,
      lag_7, lag_14, lag_30, lag_365, lag_730, alvo
    FROM `pdm-ceasa.silver.dados_treino`
    WHERE data >= '2026-01-01'
  )
);

-- Comparacao lado a lado com o baseline, mesma metrica (R2, MAE).
WITH silver_eval AS (
  SELECT
    'silver.modelo_regressao_linear' AS modelo,
    r2_score,
    mean_absolute_error
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.silver.modelo_regressao_linear`,
    (
      SELECT
        produto, classe, grupo, ano, mes, dia_semana,
        lag_7, lag_14, lag_30, lag_365, lag_730, alvo
      FROM `pdm-ceasa.silver.dados_treino`
      WHERE data >= '2026-01-01'
    )
  )
),
baseline_eval AS (
  SELECT
    'baseline.modelo_regressao_linear' AS modelo,
    MAX(IF(metrica = 'r2_score', valor, NULL)) AS r2_score,
    MAX(IF(metrica = 'mean_absolute_error', valor, NULL)) AS mean_absolute_error
  FROM `pdm-ceasa.baseline.metricas`
  WHERE modelo = 'modelo_regressao_linear'
  GROUP BY modelo
)
SELECT * FROM baseline_eval
UNION ALL
SELECT * FROM silver_eval;
