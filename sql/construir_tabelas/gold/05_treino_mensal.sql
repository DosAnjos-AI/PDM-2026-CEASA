-- Gold R5: tabela treino_mensal.
-- Faz: monta features e alvo em base mensal a partir de
-- gold.analitica_mensal (interpolacao incluida). Alvo = media_preco_comum
-- do mes seguinte do mesmo (produto, classe). Lags de 1, 12 e 24 meses
-- antes, calculados a partir do mes da propria observacao -- nunca do mes
-- do alvo.
-- Desde que a faixa media da regra de interpolacao passou a deixar buracos
-- reais em analitica_mensal (meses sem linha nenhuma), a grade deixou de
-- ser continua -- LAG/LEAD por posicao de linha nao bastam mais, pela
-- mesma razao da tabela semanal. Por isso cada lag e o alvo vem de um
-- self-join por chave_mes (ano*12+mes) deslocada exatamente 1, 12, 24
-- meses: so bate quando aquele mes existe de fato na tabela, real ou
-- interpolado por vao curto. Mesma definicao de lag de sempre, so a
-- tecnica de calculo mudou. Descarta linha com qualquer lag nulo ou sem
-- mes seguinte disponivel.
-- Nao existem lags de 7/14 dias nem lag_4s em base mensal -- nao
-- inventados aqui.
-- Nao faz: nao filtra produto, nao inclui preco_minimo/preco_maximo/
-- preco_kg como feature.
--
-- Esperado: entrada = linhas de gold.analitica_mensal; saida menor.
-- Quantidade exata e composicao dos descartes ficam na consulta de
-- conferencia (05_treino_mensal_check.sql).
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo
-- resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.gold.treino_mensal` AS
WITH base AS (
  SELECT
    produto, classe, grupo, ano, mes, media_preco_comum,
    ano * 12 + mes AS chave_mes
  FROM `pdm-ceasa.gold.analitica_mensal`
),
com_lags AS (
  SELECT
    b.produto, b.classe, b.grupo, b.ano, b.mes,
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
  produto, classe, grupo, ano, mes, lag_1m, lag_12m, lag_24m, alvo
FROM com_lags
WHERE alvo IS NOT NULL
  AND lag_1m IS NOT NULL
  AND lag_12m IS NOT NULL
  AND lag_24m IS NOT NULL;
