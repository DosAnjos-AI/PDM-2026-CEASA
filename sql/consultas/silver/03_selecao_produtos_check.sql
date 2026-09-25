-- Conferência da R5: contagem de produtos em cada checkpoint da cadeia
-- 372 -> 274 -> 224 -> 184 -> 141.

SELECT COUNT(DISTINCT produto) AS produtos_iniciais
FROM `silver.stg_02_normalizado`;

SELECT COUNT(*) AS produtos_5a_final FROM `silver.stg_03a_lista_5a`;

SELECT COUNT(*) AS produtos_5b_final FROM `silver.stg_03b_lista_final`;

SELECT
  COUNT(*) AS linhas,
  COUNT(DISTINCT produto) AS produtos
FROM `silver.stg_03_selecionado`;
