-- Gold R1: tabela analitica_semanal.
-- Faz: agrega silver.cotacoes por (produto, classe, isoyear, isoweek),
-- media das 4 colunas de preco (preco_comum, preco_minimo, preco_maximo,
-- preco_kg) e n_pregoes = quantidade de cotacoes que entraram na media.
-- O vao entre duas semanas reais consecutivas do mesmo (produto, classe)
-- cai em uma de tres faixas (vao = quantidade de semanas sem dado real
-- entre as duas observacoes reais):
--   curto (ate 4 semanas): interpola linearmente as 4 medias
--     (interpolado = TRUE, n_pregoes = 0), como antes
--   medio (5 a 26 semanas): nao interpola -- as semanas do meio ficam sem
--     linha nenhuma na tabela, historico anterior e mantido
--   longo (acima de 26 semanas): nao interpola e descarta todo o bloco
--     anterior ao vao; havendo mais de um vao longo no par, vale o ultimo
--     -- a serie do par passa a comecar na primeira semana real depois dele
-- Nunca extrapola: nao ha linha antes da primeira nem depois da ultima
-- observacao real do par (apos o corte, quando houver).
-- Usa ISOYEAR/ISOWEEK (nao semana de calendario comum), evitando semana
-- duplicada ou orfa na virada de ano.
-- Nao faz: nao corrige preco_minimo/preco_maximo incoerentes (decisao ja
-- tomada, herdada da Silver, sem sinalizacao), nao filtra produto.
--
-- Esperado: entrada = 296.545 linhas (silver.cotacoes). Contagem de saida,
-- quantidade de linhas interpoladas e pares com corte de bloco ficam na
-- consulta de conferencia (01_analitica_semanal_check.sql).
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo
-- resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.gold.analitica_semanal` AS
WITH semanal_real AS (
  SELECT
    produto,
    classe,
    ANY_VALUE(grupo) AS grupo,
    EXTRACT(ISOYEAR FROM data) AS isoyear,
    EXTRACT(ISOWEEK FROM data) AS isoweek,
    MIN(DATE_TRUNC(data, ISOWEEK)) AS data_inicio_semana,
    AVG(preco_comum) AS media_preco_comum,
    AVG(preco_minimo) AS media_preco_minimo,
    AVG(preco_maximo) AS media_preco_maximo,
    AVG(preco_kg) AS media_preco_kg,
    COUNT(*) AS n_pregoes
  FROM `pdm-ceasa.silver.cotacoes`
  GROUP BY produto, classe, isoyear, isoweek
),
classificado_bruto AS (
  -- gap_semanas = passos de 7 dias ate a semana real anterior do par;
  -- vao = gap_semanas - 1 (semanas sem dado real entre as duas). Usado so
  -- para achar o corte de faixa longa, antes de aplica-lo.
  SELECT
    *,
    DIV(DATE_DIFF(
      data_inicio_semana,
      LAG(data_inicio_semana) OVER (PARTITION BY produto, classe ORDER BY data_inicio_semana),
      DAY
    ), 7) AS gap_semanas
  FROM semanal_real
),
tipo_bruto AS (
  SELECT
    *,
    CASE
      WHEN gap_semanas IS NULL THEN NULL
      WHEN gap_semanas <= 5 THEN 'curto'
      WHEN gap_semanas <= 27 THEN 'medio'
      ELSE 'longo'
    END AS tipo_vao
  FROM classificado_bruto
),
cutoff AS (
  -- ultimo vao longo do par define o corte; sem vao longo, corte = inicio
  -- original do par (sem efeito no filtro seguinte)
  SELECT
    produto,
    classe,
    COALESCE(
      MAX(IF(tipo_vao = 'longo', data_inicio_semana, NULL)),
      MIN(data_inicio_semana)
    ) AS data_corte
  FROM tipo_bruto
  GROUP BY produto, classe
),
real_pos_corte AS (
  SELECT r.*
  FROM semanal_real AS r
  JOIN cutoff AS c
    ON c.produto = r.produto AND c.classe = r.classe
  WHERE r.data_inicio_semana >= c.data_corte
),
classificado AS (
  -- recalcula o vao so dentro do bloco que sobrevive ao corte -- a
  -- primeira semana do par pos-corte fica sem vao (LAG nulo); por
  -- construcao do corte, nenhum vao longo sobra aqui
  SELECT
    *,
    DIV(DATE_DIFF(
      data_inicio_semana,
      LAG(data_inicio_semana) OVER (PARTITION BY produto, classe ORDER BY data_inicio_semana),
      DAY
    ), 7) AS gap_semanas
  FROM real_pos_corte
),
tipo_vao AS (
  SELECT
    *,
    CASE
      WHEN gap_semanas IS NULL THEN NULL
      WHEN gap_semanas <= 5 THEN 'curto'
      WHEN gap_semanas <= 27 THEN 'medio'
      ELSE 'longo'
    END AS tipo_vao
  FROM classificado
),
vizinho_anterior AS (
  -- para cada semana real com vao curto, guarda a semana real anterior
  -- (data e as 4 medias) para gerar as semanas interpoladas entre as duas
  SELECT
    *,
    LAG(data_inicio_semana) OVER (PARTITION BY produto, classe ORDER BY data_inicio_semana) AS data_prev,
    LAG(media_preco_comum) OVER (PARTITION BY produto, classe ORDER BY data_inicio_semana) AS comum_prev,
    LAG(media_preco_minimo) OVER (PARTITION BY produto, classe ORDER BY data_inicio_semana) AS minimo_prev,
    LAG(media_preco_maximo) OVER (PARTITION BY produto, classe ORDER BY data_inicio_semana) AS maximo_prev,
    LAG(media_preco_kg) OVER (PARTITION BY produto, classe ORDER BY data_inicio_semana) AS kg_prev
  FROM tipo_vao
),
interpolado_gerado AS (
  SELECT
    v.produto,
    v.classe,
    v.grupo,
    EXTRACT(ISOYEAR FROM semana_faltante) AS isoyear,
    EXTRACT(ISOWEEK FROM semana_faltante) AS isoweek,
    semana_faltante AS data_inicio_semana,
    v.comum_prev + (v.media_preco_comum - v.comum_prev)
      * DATE_DIFF(semana_faltante, v.data_prev, DAY) / DATE_DIFF(v.data_inicio_semana, v.data_prev, DAY)
      AS media_preco_comum,
    v.minimo_prev + (v.media_preco_minimo - v.minimo_prev)
      * DATE_DIFF(semana_faltante, v.data_prev, DAY) / DATE_DIFF(v.data_inicio_semana, v.data_prev, DAY)
      AS media_preco_minimo,
    v.maximo_prev + (v.media_preco_maximo - v.maximo_prev)
      * DATE_DIFF(semana_faltante, v.data_prev, DAY) / DATE_DIFF(v.data_inicio_semana, v.data_prev, DAY)
      AS media_preco_maximo,
    v.kg_prev + (v.media_preco_kg - v.kg_prev)
      * DATE_DIFF(semana_faltante, v.data_prev, DAY) / DATE_DIFF(v.data_inicio_semana, v.data_prev, DAY)
      AS media_preco_kg,
    0 AS n_pregoes,
    TRUE AS interpolado
  FROM vizinho_anterior AS v,
  UNNEST(GENERATE_DATE_ARRAY(
    DATE_ADD(v.data_prev, INTERVAL 7 DAY),
    DATE_SUB(v.data_inicio_semana, INTERVAL 7 DAY),
    INTERVAL 7 DAY
  )) AS semana_faltante
  WHERE v.tipo_vao = 'curto'
),
real_final AS (
  SELECT
    produto, classe, grupo, isoyear, isoweek, data_inicio_semana,
    media_preco_comum, media_preco_minimo, media_preco_maximo, media_preco_kg,
    n_pregoes,
    FALSE AS interpolado
  FROM tipo_vao
)
SELECT
  produto, classe, grupo, isoyear, isoweek, data_inicio_semana,
  media_preco_comum, media_preco_minimo, media_preco_maximo, media_preco_kg,
  n_pregoes, interpolado
FROM real_final
UNION ALL
SELECT
  produto, classe, grupo, isoyear, isoweek, data_inicio_semana,
  media_preco_comum, media_preco_minimo, media_preco_maximo, media_preco_kg,
  n_pregoes, interpolado
FROM interpolado_gerado
ORDER BY media_preco_kg DESC;
