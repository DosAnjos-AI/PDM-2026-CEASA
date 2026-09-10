-- Gold R2: tabela analitica_mensal.
-- Faz: agrega silver.cotacoes por (produto, classe, ano, mes), media das 4
-- colunas de preco e n_pregoes = quantidade de cotacoes que entraram na
-- media, mais n_semanas = quantidade de semanas ISO distintas com cotacao
-- no mes. O vao entre dois meses reais consecutivos do mesmo
-- (produto, classe) cai em uma de tres faixas (vao = quantidade de meses
-- sem dado real entre as duas observacoes reais):
--   curto (ate 2 meses): interpola linearmente as 4 medias
--     (interpolado = TRUE, n_pregoes = 0, n_semanas = 0), como antes
--   medio (3 a 6 meses): nao interpola -- os meses do meio ficam sem linha
--     nenhuma na tabela, historico anterior e mantido
--   longo (acima de 6 meses): nao interpola e descarta todo o bloco
--     anterior ao vao; havendo mais de um vao longo no par, vale o ultimo
--     -- a serie do par passa a comecar no primeiro mes real depois dele
-- Nunca extrapola. A media mensal e calculada sobre os pregoes do mes, nao
-- como media das medias semanais.
-- Nao faz: nao corrige preco_minimo/preco_maximo incoerentes, nao filtra
-- produto.
--
-- Esperado: entrada = 296.545 linhas (silver.cotacoes). Contagem de saida,
-- quantidade de linhas interpoladas e pares com corte de bloco ficam na
-- consulta de conferencia (02_analitica_mensal_check.sql).
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo
-- resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.gold.analitica_mensal` AS
WITH mensal_real AS (
  SELECT
    produto,
    classe,
    ANY_VALUE(grupo) AS grupo,
    DATE_TRUNC(data, MONTH) AS data_inicio_mes,
    EXTRACT(YEAR FROM data) AS ano,
    EXTRACT(MONTH FROM data) AS mes,
    AVG(preco_comum) AS media_preco_comum,
    AVG(preco_minimo) AS media_preco_minimo,
    AVG(preco_maximo) AS media_preco_maximo,
    AVG(preco_kg) AS media_preco_kg,
    COUNT(*) AS n_pregoes,
    COUNT(DISTINCT (EXTRACT(ISOYEAR FROM data) * 100 + EXTRACT(ISOWEEK FROM data))) AS n_semanas
  FROM `pdm-ceasa.silver.cotacoes`
  GROUP BY produto, classe, data_inicio_mes, ano, mes
),
classificado_bruto AS (
  -- gap_meses = passos de 1 mes ate o mes real anterior do par;
  -- vao = gap_meses - 1 (meses sem dado real entre os dois). Usado so para
  -- achar o corte de faixa longa, antes de aplica-lo.
  SELECT
    *,
    DATE_DIFF(
      data_inicio_mes,
      LAG(data_inicio_mes) OVER (PARTITION BY produto, classe ORDER BY data_inicio_mes),
      MONTH
    ) AS gap_meses
  FROM mensal_real
),
tipo_bruto AS (
  SELECT
    *,
    CASE
      WHEN gap_meses IS NULL THEN NULL
      WHEN gap_meses <= 3 THEN 'curto'
      WHEN gap_meses <= 7 THEN 'medio'
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
      MAX(IF(tipo_vao = 'longo', data_inicio_mes, NULL)),
      MIN(data_inicio_mes)
    ) AS data_corte
  FROM tipo_bruto
  GROUP BY produto, classe
),
real_pos_corte AS (
  SELECT r.*
  FROM mensal_real AS r
  JOIN cutoff AS c
    ON c.produto = r.produto AND c.classe = r.classe
  WHERE r.data_inicio_mes >= c.data_corte
),
classificado AS (
  -- recalcula o vao so dentro do bloco que sobrevive ao corte -- o
  -- primeiro mes do par pos-corte fica sem vao (LAG nulo); por construcao
  -- do corte, nenhum vao longo sobra aqui
  SELECT
    *,
    DATE_DIFF(
      data_inicio_mes,
      LAG(data_inicio_mes) OVER (PARTITION BY produto, classe ORDER BY data_inicio_mes),
      MONTH
    ) AS gap_meses
  FROM real_pos_corte
),
tipo_vao AS (
  SELECT
    *,
    CASE
      WHEN gap_meses IS NULL THEN NULL
      WHEN gap_meses <= 3 THEN 'curto'
      WHEN gap_meses <= 7 THEN 'medio'
      ELSE 'longo'
    END AS tipo_vao
  FROM classificado
),
vizinho_anterior AS (
  -- para cada mes real com vao curto, guarda o mes real anterior (data e
  -- as 4 medias) para gerar os meses interpolados entre os dois
  SELECT
    *,
    LAG(data_inicio_mes) OVER (PARTITION BY produto, classe ORDER BY data_inicio_mes) AS data_prev,
    LAG(media_preco_comum) OVER (PARTITION BY produto, classe ORDER BY data_inicio_mes) AS comum_prev,
    LAG(media_preco_minimo) OVER (PARTITION BY produto, classe ORDER BY data_inicio_mes) AS minimo_prev,
    LAG(media_preco_maximo) OVER (PARTITION BY produto, classe ORDER BY data_inicio_mes) AS maximo_prev,
    LAG(media_preco_kg) OVER (PARTITION BY produto, classe ORDER BY data_inicio_mes) AS kg_prev
  FROM tipo_vao
),
interpolado_gerado AS (
  SELECT
    v.produto,
    v.classe,
    v.grupo,
    EXTRACT(YEAR FROM mes_faltante) AS ano,
    EXTRACT(MONTH FROM mes_faltante) AS mes,
    v.comum_prev + (v.media_preco_comum - v.comum_prev)
      * DATE_DIFF(mes_faltante, v.data_prev, MONTH) / DATE_DIFF(v.data_inicio_mes, v.data_prev, MONTH)
      AS media_preco_comum,
    v.minimo_prev + (v.media_preco_minimo - v.minimo_prev)
      * DATE_DIFF(mes_faltante, v.data_prev, MONTH) / DATE_DIFF(v.data_inicio_mes, v.data_prev, MONTH)
      AS media_preco_minimo,
    v.maximo_prev + (v.media_preco_maximo - v.maximo_prev)
      * DATE_DIFF(mes_faltante, v.data_prev, MONTH) / DATE_DIFF(v.data_inicio_mes, v.data_prev, MONTH)
      AS media_preco_maximo,
    v.kg_prev + (v.media_preco_kg - v.kg_prev)
      * DATE_DIFF(mes_faltante, v.data_prev, MONTH) / DATE_DIFF(v.data_inicio_mes, v.data_prev, MONTH)
      AS media_preco_kg,
    0 AS n_pregoes,
    0 AS n_semanas,
    TRUE AS interpolado
  FROM vizinho_anterior AS v,
  UNNEST(GENERATE_DATE_ARRAY(
    DATE_ADD(v.data_prev, INTERVAL 1 MONTH),
    DATE_SUB(v.data_inicio_mes, INTERVAL 1 MONTH),
    INTERVAL 1 MONTH
  )) AS mes_faltante
  WHERE v.tipo_vao = 'curto'
),
real_final AS (
  SELECT
    produto, classe, grupo, ano, mes,
    media_preco_comum, media_preco_minimo, media_preco_maximo, media_preco_kg,
    n_pregoes, n_semanas,
    FALSE AS interpolado
  FROM tipo_vao
)
SELECT
  produto, classe, grupo, ano, mes,
  media_preco_comum, media_preco_minimo, media_preco_maximo, media_preco_kg,
  n_pregoes, n_semanas, interpolado
FROM real_final
UNION ALL
SELECT
  produto, classe, grupo, ano, mes,
  media_preco_comum, media_preco_minimo, media_preco_maximo, media_preco_kg,
  n_pregoes, n_semanas, interpolado
FROM interpolado_gerado
ORDER BY media_preco_kg DESC;
