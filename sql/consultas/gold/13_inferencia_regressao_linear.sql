-- Inferencia dos modelos gold.modelo_regressao_linear_semanal e
-- gold.modelo_regressao_linear_mensal (LINEAR_REG elastic net, treinados
-- sobre gold.treino_semanal e gold.treino_mensal --
-- sql/modelo/gold/01_modelo_regressao_linear_semanal.sql e
-- 02_modelo_regressao_linear_mensal.sql). ML.PREDICT apenas le os modelos
-- ja treinados -- nao ha CREATE MODEL nesta consulta, nenhuma tabela e
-- criada ou alterada.
--
-- Fonte do vetor: pdm-ceasa.gold.analitica_semanal / analitica_mensal --
-- NAO treino_semanal/treino_mensal, de proposito, mesmo motivo das
-- consultas da Silver: essas tabelas so guardam periodo com alvo (periodo
-- seguinte) ja conhecido, o que descarta os periodos mais recentes -- os
-- que esta consulta precisa prever.
--
-- Grade nao continua: a regra de interpolacao de
-- sql/construir_tabelas/gold/01_analitica_semanal.sql (e 02_..._mensal.sql)
-- deixa vaos medios sem linha nenhuma. Por isso cada lag e buscado por
-- IGUALDADE EXATA de periodo via LEFT JOIN (mesma tecnica de
-- sql/construir_tabelas/gold/04_treino_semanal.sql e 05_treino_mensal.sql),
-- nunca por posicao de linha -- LAG() por posicao ja causou erro aqui
-- (achado registrado nesses dois scripts de treino).
--
-- Regra de data-base e ancora: data-base = periodo anterior ao periodo de
-- p_data_alvo (semana ISO anterior para o semanal, mes anterior para o
-- mensal). Se esse periodo exato nao existir na grade (vao), usa-se o
-- ultimo periodo real anterior ou igual a ele -- mesma logica de "ultima
-- cotacao anterior ou igual" das consultas diarias, aplicada ao grao do
-- periodo. Essa ancora efetivamente encontrada (data_base_usada) e a base
-- de tudo: grupo/isoyear/isoweek (ou ano/mes) vem dela, e cada lag_Ns/lag_Nm
-- e o periodo exatamente N passos antes da ancora -- nunca a partir de
-- p_data_alvo.
--
-- IMPORTANTE: "previsao" aqui e MEDIA DE PRECO DO PERIODO (semana/mes
-- seguinte), nao preco de um dia -- coluna unidade_previsao deixa isso
-- explicito em cada linha.
--
-- Nao faz: nao cria, nao altera nem substitui nenhuma tabela ou modelo.
--
-- Para trocar produto/classe/data prevista, editar so o bloco DECLARE
-- abaixo -- nenhum outro trecho precisa mudar. O mesmo DECLARE vale para os
-- dois blocos (semanal e mensal) abaixo. Regra do BigQuery Scripting: todo
-- DECLARE tem que vir antes de qualquer SELECT no script -- por isso as
-- variaveis auxiliares de ambos os blocos estao todas aqui no topo.

-- ===================== UNICO PONTO DE EDICAO ======================
DECLARE p_produto   STRING DEFAULT 'tomate_saladete';
DECLARE p_classe    INT64  DEFAULT 1;
DECLARE p_data_alvo DATE   DEFAULT '2026-09-04';
-- ====================================================================

DECLARE p_data_base_semana DATE DEFAULT DATE_SUB(DATE_TRUNC(p_data_alvo, ISOWEEK), INTERVAL 7 DAY);
DECLARE p_data_base_mes DATE DEFAULT DATE_SUB(DATE_TRUNC(p_data_alvo, MONTH), INTERVAL 1 MONTH);
DECLARE p_chave_mes_base INT64 DEFAULT EXTRACT(YEAR FROM p_data_base_mes) * 12 + EXTRACT(MONTH FROM p_data_base_mes);

-- ===================================== SEMANAL =====================================
WITH base AS (
  SELECT produto, classe, grupo, isoyear, isoweek, data_inicio_semana, media_preco_comum
  FROM `pdm-ceasa.gold.analitica_semanal`
  WHERE produto = p_produto AND classe = p_classe
),
data_base_encontrada AS (
  SELECT MAX(data_inicio_semana) AS data_base_usada
  FROM base
  WHERE data_inicio_semana <= p_data_base_semana
),
ancora AS (
  SELECT d.data_base_usada, b.grupo, b.isoyear, b.isoweek
  FROM data_base_encontrada AS d
  LEFT JOIN base AS b ON b.data_inicio_semana = d.data_base_usada
),
vetor AS (
  SELECT
    a.*,
    l1.media_preco_comum AS lag_1s,
    l2.media_preco_comum AS lag_2s,
    l4.media_preco_comum AS lag_4s,
    l52.media_preco_comum AS lag_52s,
    l104.media_preco_comum AS lag_104s
  FROM ancora AS a
  LEFT JOIN base AS l1 ON l1.data_inicio_semana = DATE_SUB(a.data_base_usada, INTERVAL 7 DAY)
  LEFT JOIN base AS l2 ON l2.data_inicio_semana = DATE_SUB(a.data_base_usada, INTERVAL 14 DAY)
  LEFT JOIN base AS l4 ON l4.data_inicio_semana = DATE_SUB(a.data_base_usada, INTERVAL 28 DAY)
  LEFT JOIN base AS l52 ON l52.data_inicio_semana = DATE_SUB(a.data_base_usada, INTERVAL 364 DAY)
  LEFT JOIN base AS l104 ON l104.data_inicio_semana = DATE_SUB(a.data_base_usada, INTERVAL 728 DAY)
)
SELECT
  'gold.modelo_regressao_linear_semanal' AS modelo,
  'semanal' AS granularidade,
  'media_semanal' AS unidade_previsao,
  p_produto AS produto,
  p_classe AS classe,
  p_data_alvo AS data_alvo,
  v.data_base_usada,
  v.lag_1s, v.lag_2s, v.lag_4s, v.lag_52s, v.lag_104s,
  pred.predicted_alvo AS previsao,
  CASE
    WHEN v.data_base_usada IS NULL
      THEN CONCAT('Sem semana disponivel para ', p_produto, ' classe ', CAST(p_classe AS STRING), ' em ou antes de ', CAST(p_data_base_semana AS STRING), '.')
    WHEN v.lag_1s IS NULL OR v.lag_2s IS NULL OR v.lag_4s IS NULL OR v.lag_52s IS NULL OR v.lag_104s IS NULL
      THEN 'Historico insuficiente para algum lag semanal -- previsao nao calculada.'
    ELSE NULL
  END AS observacao
FROM vetor AS v
LEFT JOIN ML.PREDICT(
  MODEL `pdm-ceasa.gold.modelo_regressao_linear_semanal`,
  (
    SELECT
      p_produto AS produto, p_classe AS classe, v.grupo AS grupo, v.isoyear AS isoyear, v.isoweek AS isoweek,
      v.lag_1s AS lag_1s, v.lag_2s AS lag_2s, v.lag_4s AS lag_4s, v.lag_52s AS lag_52s, v.lag_104s AS lag_104s
    FROM vetor AS v
    WHERE v.data_base_usada IS NOT NULL
      AND v.lag_1s IS NOT NULL AND v.lag_2s IS NOT NULL AND v.lag_4s IS NOT NULL AND v.lag_52s IS NOT NULL AND v.lag_104s IS NOT NULL
  )
) AS pred
ON TRUE;

-- ===================================== MENSAL =====================================
WITH base AS (
  SELECT produto, classe, grupo, ano, mes, media_preco_comum, ano * 12 + mes AS chave_mes
  FROM `pdm-ceasa.gold.analitica_mensal`
  WHERE produto = p_produto AND classe = p_classe
),
data_base_encontrada AS (
  SELECT MAX(chave_mes) AS chave_mes_usada
  FROM base
  WHERE chave_mes <= p_chave_mes_base
),
ancora AS (
  SELECT d.chave_mes_usada, b.grupo, b.ano, b.mes
  FROM data_base_encontrada AS d
  LEFT JOIN base AS b ON b.chave_mes = d.chave_mes_usada
),
vetor AS (
  SELECT
    a.*,
    l1.media_preco_comum AS lag_1m,
    l12.media_preco_comum AS lag_12m,
    l24.media_preco_comum AS lag_24m
  FROM ancora AS a
  LEFT JOIN base AS l1 ON l1.chave_mes = a.chave_mes_usada - 1
  LEFT JOIN base AS l12 ON l12.chave_mes = a.chave_mes_usada - 12
  LEFT JOIN base AS l24 ON l24.chave_mes = a.chave_mes_usada - 24
)
SELECT
  'gold.modelo_regressao_linear_mensal' AS modelo,
  'mensal' AS granularidade,
  'media_mensal' AS unidade_previsao,
  p_produto AS produto,
  p_classe AS classe,
  p_data_alvo AS data_alvo,
  IF(v.chave_mes_usada IS NULL, NULL, DATE(v.ano, v.mes, 1)) AS data_base_usada,
  v.lag_1m, v.lag_12m, v.lag_24m,
  pred.predicted_alvo AS previsao,
  CASE
    WHEN v.chave_mes_usada IS NULL
      THEN CONCAT('Sem mes disponivel para ', p_produto, ' classe ', CAST(p_classe AS STRING), ' em ou antes de ', CAST(p_data_base_mes AS STRING), '.')
    WHEN v.lag_1m IS NULL OR v.lag_12m IS NULL OR v.lag_24m IS NULL
      THEN 'Historico insuficiente para algum lag mensal -- previsao nao calculada.'
    ELSE NULL
  END AS observacao
FROM vetor AS v
LEFT JOIN ML.PREDICT(
  MODEL `pdm-ceasa.gold.modelo_regressao_linear_mensal`,
  (
    SELECT
      p_produto AS produto, p_classe AS classe, v.grupo AS grupo, v.ano AS ano, v.mes AS mes,
      v.lag_1m AS lag_1m, v.lag_12m AS lag_12m, v.lag_24m AS lag_24m
    FROM vetor AS v
    WHERE v.chave_mes_usada IS NOT NULL
      AND v.lag_1m IS NOT NULL AND v.lag_12m IS NOT NULL AND v.lag_24m IS NOT NULL
  )
) AS pred
ON TRUE;
