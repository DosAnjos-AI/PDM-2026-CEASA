-- Conferência obrigatória da camada Silver (secao 5 do prompt).

SELECT
  (SELECT COUNT(*) FROM `pdm-ceasa.bronze.cotacoes`) AS linhas_bronze,
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.stg_06_depara`) AS linhas_antes_r9,
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.cotacoes`) AS linhas_silver,
  (SELECT COUNT(DISTINCT produto) FROM `pdm-ceasa.silver.cotacoes`) AS produtos_distintos,
  (SELECT COUNT(DISTINCT grupo) FROM `pdm-ceasa.silver.cotacoes`) AS grupos_distintos;

SELECT DISTINCT classe FROM `pdm-ceasa.silver.cotacoes` ORDER BY classe;

SELECT MIN(data) AS data_minima, MAX(data) AS data_maxima
FROM `pdm-ceasa.silver.cotacoes`;

-- produtos que desaparecem por causa do corte de classe (esperado: nenhum)
SELECT COUNT(*) AS produtos_desaparecidos_por_r9
FROM (
  SELECT DISTINCT produto FROM `pdm-ceasa.silver.stg_06_depara`
  EXCEPT DISTINCT
  SELECT DISTINCT produto FROM `pdm-ceasa.silver.cotacoes`
);

SELECT COUNT(*) AS chaves_duplicadas
FROM (
  SELECT produto, classe, data, COUNT(*) AS n
  FROM `pdm-ceasa.silver.cotacoes`
  GROUP BY produto, classe, data
  HAVING n > 1
);

SELECT
  COUNTIF(preco_kg IS NULL OR preco_kg <= 0) AS preco_kg_invalido,
  COUNTIF(preco_comum IS NULL OR preco_comum <= 0) AS preco_comum_invalido,
  COUNTIF(qtd_kg IS NULL OR qtd_kg <= 0) AS qtd_kg_invalido
FROM `pdm-ceasa.silver.cotacoes`;
