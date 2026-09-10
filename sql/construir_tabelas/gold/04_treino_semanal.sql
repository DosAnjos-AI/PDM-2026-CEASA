-- Gold R4: tabela treino_semanal.
-- Faz: monta features e alvo em base semanal a partir de
-- gold.analitica_semanal (interpolacao incluida). Alvo = media_preco_comum
-- da semana seguinte do mesmo (produto, classe). Lags (medias de periodo,
-- nunca valor de um dia) de 1, 2, 4, 52 e 104 semanas antes, calculados a
-- partir da semana da propria observacao -- nunca da semana do alvo.
-- Desde que a faixa media da regra de interpolacao passou a deixar buracos
-- reais em analitica_semanal (semanas sem linha nenhuma), a grade deixou
-- de ser continua -- LAG/LEAD por posicao de linha nao bastam mais, porque
-- uma linha logo apos um buraco carregaria um valor de varias semanas
-- atras rotulado como lag_1s. Por isso cada lag e o alvo vem de um
-- self-join com igualdade exata de data (data_inicio_semana +/- N * 7
-- dias): so bate quando aquela semana existe de fato na tabela, real ou
-- interpolada por vao curto. Mesma definicao de lag de sempre, so a tecnica
-- de calculo mudou. Descarta linha com qualquer lag nulo ou sem semana
-- seguinte disponivel (mesma regra da Silver).
-- Nao faz: nao filtra produto, nao inclui preco_minimo/preco_maximo/
-- preco_kg como feature. data_inicio_semana fica na tabela como coluna de
-- controle para split, nao como feature.
--
-- Esperado: entrada = linhas de gold.analitica_semanal; saida menor.
-- Quantidade exata e composicao dos descartes ficam na consulta de
-- conferencia (04_treino_semanal_check.sql).
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo
-- resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.gold.treino_semanal` AS
WITH base AS (
  SELECT
    produto, classe, grupo, isoyear, isoweek, data_inicio_semana,
    media_preco_comum
  FROM `pdm-ceasa.gold.analitica_semanal`
),
com_lags AS (
  SELECT
    b.produto, b.classe, b.grupo, b.isoyear, b.isoweek, b.data_inicio_semana,
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
  produto, classe, grupo, isoyear, isoweek, data_inicio_semana,
  lag_1s, lag_2s, lag_4s, lag_52s, lag_104s, alvo
FROM com_lags
WHERE alvo IS NOT NULL
  AND lag_1s IS NOT NULL
  AND lag_2s IS NOT NULL
  AND lag_4s IS NOT NULL
  AND lag_52s IS NOT NULL
  AND lag_104s IS NOT NULL;
