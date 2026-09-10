-- Conferencia de sql/construir_tabelas/gold/05_treino_mensal.sql.
-- Faz: recalcula, a partir de gold.analitica_mensal, quantas linhas
-- perdem por alvo ausente, quantas por lag nulo, e quantas sobrevivem --
-- esse ultimo numero deve bater com COUNT(*) de gold.treino_mensal.
-- Reporta produtos que saem da tabela de treino (comparado aos 141 da
-- Silver) e prova formal de nao-vazamento: lag_1m de cada linha bate
-- exatamente com media_preco_comum do mes imediatamente anterior em
-- analitica_mensal (nunca com o mes do alvo).
-- A recontagem usa o mesmo self-join por chave_mes (ano*12+mes) que o
-- script de construcao (a grade tem buracos nos vaos medios, entao
-- LAG/LEAD por posicao de linha recontaria diferente do que a tabela
-- real tem).
-- Nao faz: nao cria nem substitui nenhuma tabela.

WITH base AS (
  SELECT
    produto, classe, ano, mes, media_preco_comum,
    ano * 12 + mes AS chave_mes
  FROM `pdm-ceasa.gold.analitica_mensal`
),
origem AS (
  SELECT
    b.produto, b.classe, b.ano, b.mes,
    l1.media_preco_comum AS lag_1m,
    l12.media_preco_comum AS lag_12m,
    l24.media_preco_comum AS lag_24m,
    alv.media_preco_comum AS alvo
  FROM base AS b
  LEFT JOIN base AS l1
    ON l1.produto = b.produto AND l1.classe = b.classe
   AND l1.chave_mes = b.chave_mes - 1
  LEFT JOIN base AS l12
    ON l12.produto = b.produto AND l12.classe = b.classe
   AND l12.chave_mes = b.chave_mes - 12
  LEFT JOIN base AS l24
    ON l24.produto = b.produto AND l24.classe = b.classe
   AND l24.chave_mes = b.chave_mes - 24
  LEFT JOIN base AS alv
    ON alv.produto = b.produto AND alv.classe = b.classe
   AND alv.chave_mes = b.chave_mes + 1
)
SELECT
  COUNT(*) AS linhas_entrada,
  COUNTIF(alvo IS NULL) AS sem_alvo,
  COUNTIF(
    alvo IS NOT NULL
    AND (lag_1m IS NULL OR lag_12m IS NULL OR lag_24m IS NULL)
  ) AS com_alvo_mas_lag_nulo,
  COUNTIF(
    lag_1m IS NOT NULL AND lag_12m IS NOT NULL AND lag_24m IS NOT NULL
    AND alvo IS NOT NULL
  ) AS linhas_finais
FROM origem;

SELECT
  COUNT(*) AS linhas_treino_mensal,
  COUNT(DISTINCT produto) AS produtos,
  COUNT(DISTINCT CONCAT(produto, '|', CAST(classe AS STRING))) AS pares,
  MIN(ano) AS ano_min,
  MAX(ano) AS ano_max
FROM `pdm-ceasa.gold.treino_mensal`;

-- produtos da Silver que saem da tabela de treino
SELECT produto
FROM (
  SELECT DISTINCT produto FROM `pdm-ceasa.silver.cotacoes`
  EXCEPT DISTINCT
  SELECT DISTINCT produto FROM `pdm-ceasa.gold.treino_mensal`
)
ORDER BY produto;

-- prova formal de nao-vazamento: lag_1m == media_preco_comum do mes
-- anterior em analitica_mensal -- esperado 0 divergencias
WITH prova AS (
  SELECT
    t.lag_1m,
    a.media_preco_comum AS preco_mes_anterior
  FROM `pdm-ceasa.gold.treino_mensal` AS t
  JOIN `pdm-ceasa.gold.analitica_mensal` AS a
    ON a.produto = t.produto
   AND a.classe = t.classe
   AND a.ano = EXTRACT(YEAR FROM DATE_SUB(DATE(t.ano, t.mes, 1), INTERVAL 1 MONTH))
   AND a.mes = EXTRACT(MONTH FROM DATE_SUB(DATE(t.ano, t.mes, 1), INTERVAL 1 MONTH))
)
SELECT
  COUNT(*) AS linhas_comparadas,
  COUNTIF(lag_1m != preco_mes_anterior) AS divergencias
FROM prova;
