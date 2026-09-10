-- Conferência da R3+R4: contagem de linhas, distintos por coluna de texto e
-- checagem de nulo novo introduzido pelo CAST numérico.

SELECT
  COUNT(*) AS total_linhas,
  COUNT(DISTINCT grupo) AS grupos_distintos,
  COUNT(DISTINCT produto) AS produtos_distintos,
  COUNT(DISTINCT embalagem) AS embalagens_distintas
FROM `pdm-ceasa.silver.stg_02_normalizado`;

-- Nulo novo: CAST(NUMERIC AS FLOAT64) só produz nulo se a origem já era
-- nula, então basta comparar a contagem agregada de nulos antes/depois.
SELECT
  'antes' AS etapa,
  COUNTIF(qtd_kg IS NULL) AS nulos_qtd_kg,
  COUNTIF(preco_comum IS NULL) AS nulos_preco_comum,
  COUNTIF(preco_maximo IS NULL) AS nulos_preco_maximo,
  COUNTIF(preco_minimo IS NULL) AS nulos_preco_minimo,
  COUNTIF(preco_kg IS NULL) AS nulos_preco_kg
FROM `pdm-ceasa.silver.stg_01_deduplicado`
UNION ALL
SELECT
  'depois' AS etapa,
  COUNTIF(qtd_kg IS NULL),
  COUNTIF(preco_comum IS NULL),
  COUNTIF(preco_maximo IS NULL),
  COUNTIF(preco_minimo IS NULL),
  COUNTIF(preco_kg IS NULL)
FROM `pdm-ceasa.silver.stg_02_normalizado`;
