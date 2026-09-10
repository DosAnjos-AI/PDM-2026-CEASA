-- Conferencia de sql/construir_tabelas/gold/04_treino_semanal.sql.
-- Faz: recalcula, a partir de gold.analitica_semanal, quantas linhas
-- perdem por alvo ausente, quantas por lag nulo, e quantas sobrevivem --
-- esse ultimo numero deve bater com COUNT(*) de gold.treino_semanal.
-- Reporta produtos que saem da tabela de treino (comparado aos 141 da
-- Silver) e prova formal de nao-vazamento: lag_1s de cada linha bate
-- exatamente com media_preco_comum da semana imediatamente anterior em
-- analitica_semanal (nunca com a semana do alvo).
-- A recontagem usa o mesmo self-join por igualdade exata de data que o
-- script de construcao (a grade tem buracos nos vaos medios, entao
-- LAG/LEAD por posicao de linha recontaria diferente do que a tabela
-- real tem).
-- Nao faz: nao cria nem substitui nenhuma tabela.

WITH base AS (
  SELECT produto, classe, data_inicio_semana, media_preco_comum
  FROM `pdm-ceasa.gold.analitica_semanal`
),
origem AS (
  SELECT
    b.produto, b.classe, b.data_inicio_semana,
    l1.media_preco_comum AS lag_1s,
    l2.media_preco_comum AS lag_2s,
    l4.media_preco_comum AS lag_4s,
    l52.media_preco_comum AS lag_52s,
    l104.media_preco_comum AS lag_104s,
    alv.media_preco_comum AS alvo
  FROM base AS b
  LEFT JOIN base AS l1
    ON l1.produto = b.produto AND l1.classe = b.classe
   AND l1.data_inicio_semana = DATE_SUB(b.data_inicio_semana, INTERVAL 7 DAY)
  LEFT JOIN base AS l2
    ON l2.produto = b.produto AND l2.classe = b.classe
   AND l2.data_inicio_semana = DATE_SUB(b.data_inicio_semana, INTERVAL 14 DAY)
  LEFT JOIN base AS l4
    ON l4.produto = b.produto AND l4.classe = b.classe
   AND l4.data_inicio_semana = DATE_SUB(b.data_inicio_semana, INTERVAL 28 DAY)
  LEFT JOIN base AS l52
    ON l52.produto = b.produto AND l52.classe = b.classe
   AND l52.data_inicio_semana = DATE_SUB(b.data_inicio_semana, INTERVAL 364 DAY)
  LEFT JOIN base AS l104
    ON l104.produto = b.produto AND l104.classe = b.classe
   AND l104.data_inicio_semana = DATE_SUB(b.data_inicio_semana, INTERVAL 728 DAY)
  LEFT JOIN base AS alv
    ON alv.produto = b.produto AND alv.classe = b.classe
   AND alv.data_inicio_semana = DATE_ADD(b.data_inicio_semana, INTERVAL 7 DAY)
)
SELECT
  COUNT(*) AS linhas_entrada,
  COUNTIF(alvo IS NULL) AS sem_alvo,
  COUNTIF(
    alvo IS NOT NULL
    AND (lag_1s IS NULL OR lag_2s IS NULL OR lag_4s IS NULL
         OR lag_52s IS NULL OR lag_104s IS NULL)
  ) AS com_alvo_mas_lag_nulo,
  COUNTIF(
    lag_1s IS NOT NULL AND lag_2s IS NOT NULL AND lag_4s IS NOT NULL
    AND lag_52s IS NOT NULL AND lag_104s IS NOT NULL AND alvo IS NOT NULL
  ) AS linhas_finais
FROM origem;

SELECT
  COUNT(*) AS linhas_treino_semanal,
  COUNT(DISTINCT produto) AS produtos,
  COUNT(DISTINCT CONCAT(produto, '|', CAST(classe AS STRING))) AS pares,
  MIN(data_inicio_semana) AS data_min,
  MAX(data_inicio_semana) AS data_max
FROM `pdm-ceasa.gold.treino_semanal`;

-- produtos da Silver que saem da tabela de treino (esperado: achado, nao
-- necessariamente vazio -- lag_104s custa as 2 primeiras temporadas)
SELECT produto
FROM (
  SELECT DISTINCT produto FROM `pdm-ceasa.silver.cotacoes`
  EXCEPT DISTINCT
  SELECT DISTINCT produto FROM `pdm-ceasa.gold.treino_semanal`
)
ORDER BY produto;

-- prova formal de nao-vazamento: lag_1s == media_preco_comum da semana
-- anterior em analitica_semanal -- esperado 0 divergencias
WITH prova AS (
  SELECT
    t.lag_1s,
    a.media_preco_comum AS preco_semana_anterior
  FROM `pdm-ceasa.gold.treino_semanal` AS t
  JOIN `pdm-ceasa.gold.analitica_semanal` AS a
    ON a.produto = t.produto
   AND a.classe = t.classe
   AND a.data_inicio_semana = DATE_SUB(t.data_inicio_semana, INTERVAL 7 DAY)
)
SELECT
  COUNT(*) AS linhas_comparadas,
  COUNTIF(lag_1s != preco_semana_anterior) AS divergencias
FROM prova;
