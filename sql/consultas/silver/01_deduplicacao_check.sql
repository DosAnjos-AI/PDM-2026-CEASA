-- Conferência da R1+R2: prova as contagens antes/depois de cada deduplicação.

SELECT
  (SELECT COUNT(*) FROM `pdm-ceasa.bronze.cotacoes`) AS bronze_total,
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.stg_01a_dedup_total`) AS apos_r1,
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.stg_01_deduplicado`) AS apos_r2;
