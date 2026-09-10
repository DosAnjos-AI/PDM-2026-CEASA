-- Previsoes dos 6 modelos gold para as 3 datas do recorte de demo
-- (2026-09-01, 2026-09-03, 2026-09-04), no mesmo formato usado em
-- sql/consultas/metricas/02_previsoes_demo.sql (bronze/silver), com a
-- coluna granularidade a mais, para casamento em Python contra o valor
-- observado do recorte.
--
-- Convencao obrigatoria de granularidade (declarada no prompt): a Gold
-- preve media de periodo (semana/mes), nao preco de um dia. Convencao
-- adotada: comparar a previsao do periodo que CONTEM cada data com o
-- observado daquele dia. As 3 datas de demo caem na mesma semana ISO
-- (inicio em 2026-08-31, segunda-feira) e no mesmo mes (setembro de 2026) --
-- confirmado por calculo de calendario antes de escrever esta consulta, nao
-- suposto. Por isso ha exatamente UMA previsao semanal e UMA previsao
-- mensal por modelo, repetida para as 3 datas via CROSS JOIN.
--
-- Faz: ML.PREDICT (linear e arvore, semanal e mensal) e ML.FORECAST (ARIMA,
-- semanal e mensal), todos sobre modelo ja treinado. Vetor de entrada
-- identico ao treino, ancorado no periodo alvo (semana de 2026-08-31 /
-- mes 2026-09), com lags buscados por igualdade exata de data em
-- gold.analitica_semanal / gold.analitica_mensal -- mesma tecnica de
-- sql/construir_tabelas/gold/04_treino_semanal.sql e 05_treino_mensal.sql,
-- porque a grade tem buracos reais e LAG/LEAD por posicao nao serve.
-- Universo de pares (produto, classe, grupo): todos os distintos em
-- gold.analitica_semanal / gold.analitica_mensal (210 cada) -- alguns podem
-- ficar com lag nulo se a semana/mes de referencia nao existir na tabela
-- (buraco real); ML.PREDICT roda mesmo assim, mesmo padrao ja aceito em
-- sql/consultas/metricas/02_previsoes_demo.sql para a Silver.
--
-- Nao faz: nao contem CREATE MODEL nem CREATE OR REPLACE MODEL. Nao grava
-- nenhuma tabela -- consulta pura, consumida por
-- scripts/metricas_demo_gold.py via "bq query ... --format=csv". Nao le nem
-- referencia o recorte local -- esse arquivo so entra no lado Python.

WITH datas AS (
  SELECT data FROM UNNEST([DATE '2026-09-01', DATE '2026-09-03', DATE '2026-09-04']) AS data
),

-- ===== SEMANAL =====
-- Periodo alvo: semana ISO que contem as 3 datas de demo, inicio 2026-08-31.
pares_semanal AS (
  SELECT produto, classe, ANY_VALUE(grupo) AS grupo
  FROM `pdm-ceasa.gold.analitica_semanal`
  GROUP BY produto, classe
),
entrada_semanal AS (
  SELECT
    p.produto, p.classe, p.grupo,
    DATE '2026-08-31' AS periodo,
    EXTRACT(ISOYEAR FROM DATE '2026-08-31') AS isoyear,
    EXTRACT(ISOWEEK FROM DATE '2026-08-31') AS isoweek,
    l1.media_preco_comum AS lag_1s,
    l2.media_preco_comum AS lag_2s,
    l4.media_preco_comum AS lag_4s,
    l52.media_preco_comum AS lag_52s,
    l104.media_preco_comum AS lag_104s
  FROM pares_semanal AS p
  LEFT JOIN `pdm-ceasa.gold.analitica_semanal` AS l1
    ON l1.produto = p.produto AND l1.classe = p.classe
   AND l1.data_inicio_semana = DATE_SUB(DATE '2026-08-31', INTERVAL 7 DAY)
  LEFT JOIN `pdm-ceasa.gold.analitica_semanal` AS l2
    ON l2.produto = p.produto AND l2.classe = p.classe
   AND l2.data_inicio_semana = DATE_SUB(DATE '2026-08-31', INTERVAL 14 DAY)
  LEFT JOIN `pdm-ceasa.gold.analitica_semanal` AS l4
    ON l4.produto = p.produto AND l4.classe = p.classe
   AND l4.data_inicio_semana = DATE_SUB(DATE '2026-08-31', INTERVAL 28 DAY)
  LEFT JOIN `pdm-ceasa.gold.analitica_semanal` AS l52
    ON l52.produto = p.produto AND l52.classe = p.classe
   AND l52.data_inicio_semana = DATE_SUB(DATE '2026-08-31', INTERVAL 364 DAY)
  LEFT JOIN `pdm-ceasa.gold.analitica_semanal` AS l104
    ON l104.produto = p.produto AND l104.classe = p.classe
   AND l104.data_inicio_semana = DATE_SUB(DATE '2026-08-31', INTERVAL 728 DAY)
),

gold_linear_semanal AS (
  SELECT
    'gold' AS camada, 'regressao_linear' AS modelo, 'semanal' AS granularidade,
    produto, classe, predicted_alvo AS preco_previsto
  FROM ML.PREDICT(
    MODEL `pdm-ceasa.gold.modelo_regressao_linear_semanal`,
    (SELECT produto, classe, grupo, isoyear, isoweek, lag_1s, lag_2s, lag_4s, lag_52s, lag_104s FROM entrada_semanal)
  )
),

gold_arvore_semanal AS (
  SELECT
    'gold' AS camada, 'regressao_arvore' AS modelo, 'semanal' AS granularidade,
    produto, classe, predicted_alvo AS preco_previsto
  FROM ML.PREDICT(
    MODEL `pdm-ceasa.gold.modelo_regressao_arvore_semanal`,
    (SELECT produto, classe, grupo, isoyear, isoweek, lag_1s, lag_2s, lag_4s, lag_52s, lag_104s FROM entrada_semanal)
  )
),

gold_arima_semanal AS (
  SELECT
    'gold' AS camada, 'serie_arima' AS modelo, 'semanal' AS granularidade,
    produto, classe, forecast_value AS preco_previsto
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.gold.modelo_serie_arima_semanal`,
    STRUCT(90 AS horizon)
  )
  WHERE DATE(forecast_timestamp) = DATE '2026-08-31'
),

-- ===== MENSAL =====
-- Periodo alvo: mes que contem as 3 datas de demo -- setembro de 2026.
pares_mensal AS (
  SELECT produto, classe, ANY_VALUE(grupo) AS grupo
  FROM `pdm-ceasa.gold.analitica_mensal`
  GROUP BY produto, classe
),
entrada_mensal AS (
  SELECT
    p.produto, p.classe, p.grupo,
    2026 AS ano,
    9 AS mes,
    l1.media_preco_comum AS lag_1m,
    l12.media_preco_comum AS lag_12m,
    l24.media_preco_comum AS lag_24m
  FROM pares_mensal AS p
  LEFT JOIN `pdm-ceasa.gold.analitica_mensal` AS l1
    ON l1.produto = p.produto AND l1.classe = p.classe AND l1.ano = 2026 AND l1.mes = 8
  LEFT JOIN `pdm-ceasa.gold.analitica_mensal` AS l12
    ON l12.produto = p.produto AND l12.classe = p.classe AND l12.ano = 2025 AND l12.mes = 9
  LEFT JOIN `pdm-ceasa.gold.analitica_mensal` AS l24
    ON l24.produto = p.produto AND l24.classe = p.classe AND l24.ano = 2024 AND l24.mes = 9
),

gold_linear_mensal AS (
  SELECT
    'gold' AS camada, 'regressao_linear' AS modelo, 'mensal' AS granularidade,
    produto, classe, predicted_alvo AS preco_previsto
  FROM ML.PREDICT(
    MODEL `pdm-ceasa.gold.modelo_regressao_linear_mensal`,
    (SELECT produto, classe, grupo, ano, mes, lag_1m, lag_12m, lag_24m FROM entrada_mensal)
  )
),

gold_arvore_mensal AS (
  SELECT
    'gold' AS camada, 'regressao_arvore' AS modelo, 'mensal' AS granularidade,
    produto, classe, predicted_alvo AS preco_previsto
  FROM ML.PREDICT(
    MODEL `pdm-ceasa.gold.modelo_regressao_arvore_mensal`,
    (SELECT produto, classe, grupo, ano, mes, lag_1m, lag_12m, lag_24m FROM entrada_mensal)
  )
),

gold_arima_mensal AS (
  SELECT
    'gold' AS camada, 'serie_arima' AS modelo, 'mensal' AS granularidade,
    produto, classe, forecast_value AS preco_previsto
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.gold.modelo_serie_arima_mensal`,
    STRUCT(24 AS horizon)
  )
  WHERE DATE(forecast_timestamp) = DATE '2026-09-01'
),

todas AS (
  SELECT * FROM gold_linear_semanal
  UNION ALL SELECT * FROM gold_arvore_semanal
  UNION ALL SELECT * FROM gold_arima_semanal
  UNION ALL SELECT * FROM gold_linear_mensal
  UNION ALL SELECT * FROM gold_arvore_mensal
  UNION ALL SELECT * FROM gold_arima_mensal
)

-- CROSS JOIN com as 3 datas: mesma previsao de periodo repetida para cada
-- data que o periodo contem -- e a convencao declarada acima.
SELECT
  t.camada, t.modelo, t.granularidade,
  t.produto, t.classe, d.data,
  t.preco_previsto
FROM todas AS t
CROSS JOIN datas AS d
ORDER BY modelo, granularidade, produto, classe, data;
