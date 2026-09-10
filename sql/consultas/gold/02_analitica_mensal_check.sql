-- Conferencia de sql/construir_tabelas/gold/02_analitica_mensal.sql.
-- Faz: reporta linhas totais e interpoladas, distribuicao de n_semanas
-- por mes (so meses com pregao real), maior vao continuo interpolado por
-- (produto, classe), e prova de que nenhuma linha interpolada aparece
-- antes do primeiro ou depois do ultimo mes real de cada par.
-- Nao faz: nao cria nem substitui nenhuma tabela.

SELECT
  COUNT(*) AS linhas_totais,
  COUNTIF(interpolado) AS linhas_interpoladas,
  COUNTIF(NOT interpolado) AS linhas_reais,
  COUNT(DISTINCT CONCAT(produto, '|', CAST(classe AS STRING))) AS pares
FROM `pdm-ceasa.gold.analitica_mensal`;

-- distribuicao de n_semanas por mes (apenas meses com pregao real)
SELECT
  MIN(n_semanas) AS min_n_semanas,
  APPROX_QUANTILES(n_semanas, 2)[OFFSET(1)] AS mediana_n_semanas,
  MAX(n_semanas) AS max_n_semanas
FROM `pdm-ceasa.gold.analitica_mensal`
WHERE NOT interpolado;

-- distribuicao completa de n_semanas (achado se aparecer 6+ semanas)
SELECT n_semanas, COUNT(*) AS quantidade
FROM `pdm-ceasa.gold.analitica_mensal`
WHERE NOT interpolado
GROUP BY n_semanas
ORDER BY n_semanas;

-- maior vao continuo interpolado (em meses), por produto/classe
WITH indexado AS (
  SELECT
    produto, classe, ano, mes, interpolado,
    ROW_NUMBER() OVER (PARTITION BY produto, classe ORDER BY ano, mes) AS idx
  FROM `pdm-ceasa.gold.analitica_mensal`
),
somente_interpolado AS (
  SELECT
    produto, classe, idx,
    idx - ROW_NUMBER() OVER (PARTITION BY produto, classe ORDER BY idx) AS ilha
  FROM indexado
  WHERE interpolado
),
tamanho_ilha AS (
  SELECT produto, classe, ilha, COUNT(*) AS tamanho
  FROM somente_interpolado
  GROUP BY produto, classe, ilha
)
SELECT produto, classe, tamanho AS maior_vao_meses
FROM tamanho_ilha
ORDER BY tamanho DESC
LIMIT 10;

-- prova: nenhuma linha interpolada nas pontas (primeiro ou ultimo mes de
-- cada par) -- esperado 0
WITH indexado AS (
  SELECT
    interpolado,
    ROW_NUMBER() OVER (PARTITION BY produto, classe ORDER BY ano, mes) AS idx,
    COUNT(*) OVER (PARTITION BY produto, classe) AS total
  FROM `pdm-ceasa.gold.analitica_mensal`
)
SELECT COUNT(*) AS violacoes_ponta
FROM indexado
WHERE (idx = 1 OR idx = total) AND interpolado;
