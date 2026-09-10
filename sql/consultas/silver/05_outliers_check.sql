-- Conferência da R7: total antes/depois.

SELECT
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.stg_04_preco_coerente`) AS antes,
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.stg_05_sem_outliers`) AS depois;
