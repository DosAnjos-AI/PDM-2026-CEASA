-- Silver R5: filtro de densidade de produtos, em duas etapas encadeadas,
-- medidas em janelas diferentes.
-- Faz: (5a) sobre a série 2017+, mantém produtos com cotação em
-- 2026-06-01+, primeira data anterior a 2023-01-01, e densidade >= 80% na
-- janela 2017+; (5b) recalcula a densidade dos sobreviventes na série
-- completa (2010+) e mantém quem tem densidade >= 92%.
-- Não faz: não corrige preço, não deduplica, não descarta produto por nome
-- individual (isso é a R8, em outro arquivo).
--
-- Densidade = pregões em que o produto foi cotado / pregões existentes na
-- base inteira dentro do intervalo [primeira data, última data] do próprio
-- produto (na janela sendo medida).
--
-- Esperado: 372 -> 274 (corte 1) -> 224 (corte 2) -> 184 (corte 3, R5a) ->
-- 141 (R5b).
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.silver.stg_03a_lista_5a` AS
WITH produto_stats_geral AS (
  SELECT produto, MIN(data) AS primeira_data, MAX(data) AS ultima_data
  FROM `pdm-ceasa.silver.stg_02_normalizado`
  GROUP BY produto
),
sobreviventes_1_2 AS (
  SELECT produto
  FROM produto_stats_geral
  WHERE ultima_data >= '2026-06-01'
    AND primeira_data < '2023-01-01'
),
base_2017 AS (
  SELECT *
  FROM `pdm-ceasa.silver.stg_02_normalizado`
  WHERE data >= '2017-01-01'
),
calendario_2017 AS (
  SELECT DISTINCT data FROM base_2017
),
produto_stats_2017 AS (
  SELECT
    produto,
    MIN(data) AS primeira_data,
    MAX(data) AS ultima_data,
    COUNT(DISTINCT data) AS pregoes_cotados
  FROM base_2017
  WHERE produto IN (SELECT produto FROM sobreviventes_1_2)
  GROUP BY produto
),
densidade_2017 AS (
  SELECT
    p.produto,
    p.pregoes_cotados,
    (
      SELECT COUNT(*) FROM calendario_2017 c
      WHERE c.data BETWEEN p.primeira_data AND p.ultima_data
    ) AS pregoes_existentes
  FROM produto_stats_2017 p
)
SELECT produto
FROM densidade_2017
WHERE pregoes_cotados / pregoes_existentes >= 0.80;

CREATE OR REPLACE TABLE `pdm-ceasa.silver.stg_03b_lista_final` AS
WITH calendario_total AS (
  SELECT DISTINCT data FROM `pdm-ceasa.silver.stg_02_normalizado`
),
produto_stats_total AS (
  SELECT
    produto,
    MIN(data) AS primeira_data,
    MAX(data) AS ultima_data,
    COUNT(DISTINCT data) AS pregoes_cotados
  FROM `pdm-ceasa.silver.stg_02_normalizado`
  WHERE produto IN (SELECT produto FROM `pdm-ceasa.silver.stg_03a_lista_5a`)
  GROUP BY produto
),
densidade_total AS (
  SELECT
    p.produto,
    p.pregoes_cotados,
    (
      SELECT COUNT(*) FROM calendario_total c
      WHERE c.data BETWEEN p.primeira_data AND p.ultima_data
    ) AS pregoes_existentes
  FROM produto_stats_total p
)
SELECT produto
FROM densidade_total
WHERE pregoes_cotados / pregoes_existentes >= 0.92;

CREATE OR REPLACE TABLE `pdm-ceasa.silver.stg_03_selecionado` AS
SELECT *
FROM `pdm-ceasa.silver.stg_02_normalizado`
WHERE produto IN (SELECT produto FROM `pdm-ceasa.silver.stg_03b_lista_final`);
