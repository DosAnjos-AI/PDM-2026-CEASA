-- Conferência da R6: total antes/depois e decomposição do motivo de descarte.

SELECT
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.stg_03_selecionado`) AS antes,
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.stg_04_preco_coerente`) AS depois;

SELECT
  COUNTIF(qtd_kg IS NULL OR qtd_kg = 0 OR preco_comum = 0) AS base_calculo_invalida,
  COUNTIF(
    NOT (qtd_kg IS NULL OR qtd_kg = 0 OR preco_comum = 0)
    AND ABS(preco_kg - SAFE_DIVIDE(preco_comum, qtd_kg)) / SAFE_DIVIDE(preco_comum, qtd_kg) > 0.01
  ) AS incoerencia
FROM `pdm-ceasa.silver.stg_03_selecionado`;
