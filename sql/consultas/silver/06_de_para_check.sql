-- Conferência da R8: total antes/depois, produtos distintos, e ausência de
-- conflito de chave (produto, classe, data) gerado pela unificação.

SELECT
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.stg_05_sem_outliers`) AS antes,
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.stg_06_depara`) AS depois,
  (SELECT COUNT(DISTINCT produto) FROM `pdm-ceasa.silver.stg_06_depara`) AS produtos_distintos;

SELECT COUNT(*) AS chaves_duplicadas
FROM (
  SELECT produto, classe, data, COUNT(*) AS n
  FROM `pdm-ceasa.silver.stg_06_depara`
  GROUP BY produto, classe, data
  HAVING n > 1
);
