-- Tabela de features para o modelo de regressão linear elastic net.
-- Faz: monta o alvo (preco_comum em D+7, mesmo produto/classe) e cinco
-- lags de preco_comum (7, 14, 30, 365, 730 dias) por (produto, classe),
-- deriva dia_semana a partir de data, e descarta linha sem alvo ou com
-- qualquer lag nulo.
-- Nao faz: nao filtra produto, nao corrige preco (ja aconteceu na Silver),
-- nao inclui preco_kg/preco_maximo/preco_minimo/qtd_kg/embalagem/dia --
-- excluidos por vazamento, indisponibilidade no momento da previsao ou
-- informacao nula (ver secao 2.4 do prompt). data permanece na tabela como
-- coluna de controle para split e conferencia, nao como feature de modelo.
--
-- Regra critica anti-vazamento: cada lag_N e calculado a partir de "data"
-- (a data da propria observacao), nunca a partir da data do alvo (D+7).
-- lag_N = ultima cotacao com data <= data - N dias, do mesmo produto/classe.
--
-- Consequencia aceita: linhas cujo produto nao tem 730 dias de historico
-- anterior saem por lag_730 nulo -- perde os ~2 primeiros anos de serie
-- por produto. Contagem exata na consulta de conferencia
-- (08_dados_treino_check.sql).
--
-- Esperado: entrada de 296.545 linhas (silver.cotacoes); saida menor,
-- quantidade exata e composicao dos descartes ficam na consulta de
-- conferencia.
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.silver.dados_treino` AS
WITH serie AS (
  SELECT
    produto,
    classe,
    ARRAY_AGG(STRUCT(data AS data, preco_comum AS preco_comum) ORDER BY data) AS pregoes
  FROM `pdm-ceasa.silver.cotacoes`
  GROUP BY produto, classe
),
com_features AS (
  SELECT
    c.data,
    c.ano,
    c.mes,
    EXTRACT(DAYOFWEEK FROM c.data) AS dia_semana,
    c.grupo,
    c.produto,
    c.classe,
    (
      SELECT p.preco_comum
      FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 7 DAY)
      ORDER BY p.data DESC
      LIMIT 1
    ) AS lag_7,
    (
      SELECT p.preco_comum
      FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 14 DAY)
      ORDER BY p.data DESC
      LIMIT 1
    ) AS lag_14,
    (
      SELECT p.preco_comum
      FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 30 DAY)
      ORDER BY p.data DESC
      LIMIT 1
    ) AS lag_30,
    (
      SELECT p.preco_comum
      FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 365 DAY)
      ORDER BY p.data DESC
      LIMIT 1
    ) AS lag_365,
    (
      SELECT p.preco_comum
      FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= DATE_SUB(c.data, INTERVAL 730 DAY)
      ORDER BY p.data DESC
      LIMIT 1
    ) AS lag_730,
    (
      SELECT p.preco_comum
      FROM UNNEST(s.pregoes) AS p
      WHERE p.data >= DATE_ADD(c.data, INTERVAL 7 DAY)
      ORDER BY p.data ASC
      LIMIT 1
    ) AS alvo
  FROM `pdm-ceasa.silver.cotacoes` AS c
  JOIN serie AS s
    ON s.produto = c.produto
   AND s.classe = c.classe
)
SELECT
  data, ano, mes, dia_semana, grupo, produto, classe,
  lag_7, lag_14, lag_30, lag_365, lag_730, alvo
FROM com_features
WHERE alvo IS NOT NULL
  AND lag_7 IS NOT NULL
  AND lag_14 IS NOT NULL
  AND lag_30 IS NOT NULL
  AND lag_365 IS NOT NULL
  AND lag_730 IS NOT NULL;
