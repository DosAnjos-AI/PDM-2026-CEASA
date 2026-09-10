-- Conferencia de sql/construir_tabelas/gold/01_analitica_semanal.sql.
-- Faz: reporta linhas totais e interpoladas, distribuicao de n_pregoes
-- por semana (so semanas com pregao real), maior vao continuo
-- interpolado por (produto, classe), e prova de que nenhuma linha
-- interpolada aparece antes da primeira ou depois da ultima semana real
-- de cada par.
-- Nao faz: nao cria nem substitui nenhuma tabela.

SELECT
  COUNT(*) AS linhas_totais,
  COUNTIF(interpolado) AS linhas_interpoladas,
  COUNTIF(NOT interpolado) AS linhas_reais,
  COUNT(DISTINCT CONCAT(produto, '|', CAST(classe AS STRING))) AS pares
FROM `pdm-ceasa.gold.analitica_semanal`;

-- distribuicao de n_pregoes por semana (apenas semanas com pregao real)
SELECT
  MIN(n_pregoes) AS min_n_pregoes,
  APPROX_QUANTILES(n_pregoes, 2)[OFFSET(1)] AS mediana_n_pregoes,
  MAX(n_pregoes) AS max_n_pregoes
FROM `pdm-ceasa.gold.analitica_semanal`
WHERE NOT interpolado;

-- distribuicao completa de n_pregoes (achado se aparecer 7+ pregoes)
SELECT n_pregoes, COUNT(*) AS quantidade
FROM `pdm-ceasa.gold.analitica_semanal`
WHERE NOT interpolado
GROUP BY n_pregoes
ORDER BY n_pregoes;

-- maior vao continuo interpolado (em semanas), por produto/classe
WITH indexado AS (
  SELECT
    produto, classe, data_inicio_semana, interpolado,
    ROW_NUMBER() OVER (PARTITION BY produto, classe ORDER BY data_inicio_semana) AS idx
  FROM `pdm-ceasa.gold.analitica_semanal`
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
SELECT produto, classe, tamanho AS maior_vao_semanas
FROM tamanho_ilha
ORDER BY tamanho DESC
LIMIT 10;

-- prova: nenhuma linha interpolada nas pontas (primeira ou ultima semana
-- de cada par) -- esperado 0
WITH indexado AS (
  SELECT
    interpolado,
    ROW_NUMBER() OVER (PARTITION BY produto, classe ORDER BY data_inicio_semana) AS idx,
    COUNT(*) OVER (PARTITION BY produto, classe) AS total
  FROM `pdm-ceasa.gold.analitica_semanal`
)
SELECT COUNT(*) AS violacoes_ponta
FROM indexado
WHERE (idx = 1 OR idx = total) AND interpolado;
