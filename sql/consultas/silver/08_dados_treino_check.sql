-- Conferencia de sql/construir_tabelas/silver/08_dados_treino.sql.
-- Faz: recalcula alvo e os 5 lags para as 296.545 linhas de
-- silver.cotacoes (independente da tabela dados_treino ja materializada)
-- e reporta quantas linhas perdem por alvo ausente, quantas por lag nulo
-- (qualquer um dos 5) e quantas sobrevivem aos dois filtros -- esse ultimo
-- numero deve bater com COUNT(*) de silver.dados_treino. Reporta tambem,
-- a partir da tabela ja materializada, produtos distintos, data minima e
-- maxima, e linhas por particao de treino/teste.
-- Nao faz: nao cria nem substitui nenhuma tabela.
--
-- Esperado: "linhas_finais" desta consulta == COUNT(*) de
-- silver.dados_treino. Qualquer divergencia e achado, nao ruido.

WITH serie AS (
  SELECT
    produto,
    classe,
    ARRAY_AGG(STRUCT(data AS data, preco_comum AS preco_comum) ORDER BY data) AS pregoes
  FROM `pdm-ceasa.silver.cotacoes`
  GROUP BY produto, classe
),
recalculo AS (
  SELECT
    c.data,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data >= DATE_ADD(c.data, INTERVAL 7 DAY)
      ORDER BY p.data ASC LIMIT 1
    ) AS alvo,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 7 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_7,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 14 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_14,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 30 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_30,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 365 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_365,
    (
      SELECT p.preco_comum FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 730 DAY)
      ORDER BY p.data DESC LIMIT 1
    ) AS lag_730
  FROM `pdm-ceasa.silver.cotacoes` AS c
  JOIN serie AS s ON s.produto = c.produto AND s.classe = c.classe
),
resumo_descarte AS (
  SELECT
    COUNT(*) AS linhas_entrada,
    COUNTIF(alvo IS NULL) AS sem_alvo,
    COUNTIF(
      alvo IS NOT NULL
      AND (lag_7 IS NULL OR lag_14 IS NULL OR lag_30 IS NULL
           OR lag_365 IS NULL OR lag_730 IS NULL)
    ) AS com_alvo_mas_lag_nulo,
    COUNTIF(
      lag_7 IS NULL OR lag_14 IS NULL OR lag_30 IS NULL
      OR lag_365 IS NULL OR lag_730 IS NULL
    ) AS com_algum_lag_nulo,
    COUNTIF(
      alvo IS NOT NULL AND lag_7 IS NOT NULL AND lag_14 IS NOT NULL
      AND lag_30 IS NOT NULL AND lag_365 IS NOT NULL AND lag_730 IS NOT NULL
    ) AS linhas_finais
  FROM recalculo
),
resumo_tabela AS (
  SELECT
    COUNT(*) AS linhas_dados_treino,
    COUNT(DISTINCT produto) AS produtos,
    MIN(data) AS data_min,
    MAX(data) AS data_max,
    COUNTIF(data <= '2025-12-31') AS linhas_treino,
    COUNTIF(data >= '2026-01-01') AS linhas_teste
  FROM `pdm-ceasa.silver.dados_treino`
)
SELECT * FROM resumo_descarte, resumo_tabela;
