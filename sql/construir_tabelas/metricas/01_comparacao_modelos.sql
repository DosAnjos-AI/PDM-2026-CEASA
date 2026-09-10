-- Cria o dataset metricas (regiao US, igual aos demais datasets do projeto)
-- e a tabela comparacao_modelos, que consolida numa unica tabela as
-- metricas de avaliacao dos modelos ja treinados em baseline (bronze) e
-- silver, permitindo comparar cru vs. tratado num unico SELECT.
--
-- Dois blocos de metrica por linha:
-- - Bloco formal (r2, mae, mse, rmse): ML.EVALUATE sobre a particao de
--   teste data >= 2026-01-01, nunca vista no treino. ARIMA fica NULL, sem
--   particao de teste.
-- - Bloco demo (mae_demo, mse_demo, rmse_demo, n_obs_demo): comeca NULL
--   aqui -- este script so define o esquema. Quem preenche esses quatro
--   valores e sql/consultas/metricas/02_previsoes_demo.sql +
--   scripts/metricas_demo.py, via UPDATE, porque o calculo depende do
--   recorte local (~/Dropbox/PDM/recorte/cotacoes_recorte_demo.csv) que
--   nao pode ser lido de dentro do BigQuery.
--
-- Faz: le os tres modelos de cada camada via ML.EVALUATE (regressao linear
-- e regressao arvore, sobre a particao de teste data >= 2026-01-01, nunca
-- vista no treino) e registra os dois modelos ARIMA com metricas formais
-- nulas, pois nao tem particao de teste -- decisao ja registrada no
-- inventario, nao omissao.
--
-- Nao faz: nao treina nem retreina nenhum modelo. Este arquivo nao contem
-- CREATE MODEL nem CREATE OR REPLACE MODEL em nenhuma linha. ML.EVALUATE
-- apenas le um modelo ja treinado, e e seguro reexecutar. Nao calcula nem
-- grava o bloco demo -- ver scripts/metricas_demo.py.
--
-- Esperado: 6 linhas -- bronze/regressao_linear, bronze/regressao_arvore,
-- bronze/serie_arima, silver/regressao_linear, silver/regressao_arvore,
-- silver/serie_arima.
--
-- CREATE OR REPLACE TABLE: idempotente para o bloco formal. Reexecutar
-- este script reconstroi a tabela do zero a partir dos modelos ja
-- treinados e ZERA o bloco demo (volta a NULL) -- rodar
-- scripts/metricas_demo.py de novo em seguida para repreenche-lo.

CREATE SCHEMA IF NOT EXISTS `pdm-ceasa.metricas`
OPTIONS (location = 'US');

CREATE OR REPLACE TABLE `pdm-ceasa.metricas.comparacao_modelos` AS

WITH bronze_linear AS (
  SELECT
    'bronze' AS camada,
    'regressao_linear' AS modelo,
    r2_score AS r2,
    mean_absolute_error AS mae,
    mean_squared_error AS mse,
    SQRT(mean_squared_error) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo,
    CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo,
    CAST(NULL AS INT64) AS n_obs_demo,
    'instavel: entre execucoes identicas variou de R2 -180.271 para -1.535.675' AS observacao
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.baseline.modelo_regressao_linear`,
    (
      SELECT produto, classe, mes, dia_semana, alvo
      FROM `pdm-ceasa.baseline.dados_treino`
      WHERE data >= '2026-01-01'
    )
  )
),

bronze_arvore AS (
  SELECT
    'bronze' AS camada,
    'regressao_arvore' AS modelo,
    r2_score AS r2,
    mean_absolute_error AS mae,
    mean_squared_error AS mse,
    SQRT(mean_squared_error) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo,
    CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo,
    CAST(NULL AS INT64) AS n_obs_demo,
    CAST(NULL AS STRING) AS observacao
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.baseline.modelo_regressao_arvore`,
    (
      SELECT produto, classe, mes, dia_semana, alvo
      FROM `pdm-ceasa.baseline.dados_treino`
      WHERE data >= '2026-01-01'
    )
  )
),

bronze_arima AS (
  SELECT
    'bronze' AS camada,
    'serie_arima' AS modelo,
    CAST(NULL AS FLOAT64) AS r2,
    CAST(NULL AS FLOAT64) AS mae,
    CAST(NULL AS FLOAT64) AS mse,
    CAST(NULL AS FLOAT64) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo,
    CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo,
    CAST(NULL AS INT64) AS n_obs_demo,
    'sem particao de teste - bloco formal nulo; avaliado nas 3 datas da demo' AS observacao
),

silver_linear AS (
  SELECT
    'silver' AS camada,
    'regressao_linear' AS modelo,
    r2_score AS r2,
    mean_absolute_error AS mae,
    mean_squared_error AS mse,
    SQRT(mean_squared_error) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo,
    CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo,
    CAST(NULL AS INT64) AS n_obs_demo,
    'elastic net, L1=1.0 e L2=1.0; features incluem 5 lags - a comparacao com a bronze mede limpeza e engenharia de features somadas' AS observacao
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.silver.modelo_regressao_linear`,
    (
      SELECT
        produto, classe, grupo, ano, mes, dia_semana,
        lag_7, lag_14, lag_30, lag_365, lag_730, alvo
      FROM `pdm-ceasa.silver.dados_treino`
      WHERE data >= '2026-01-01'
    )
  )
),

silver_arvore AS (
  SELECT
    'silver' AS camada,
    'regressao_arvore' AS modelo,
    r2_score AS r2,
    mean_absolute_error AS mae,
    mean_squared_error AS mse,
    SQRT(mean_squared_error) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo,
    CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo,
    CAST(NULL AS INT64) AS n_obs_demo,
    'features incluem 5 lags - a comparacao com a bronze mede limpeza e engenharia de features somadas' AS observacao
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.silver.modelo_regressao_arvore`,
    (
      SELECT
        produto, classe, grupo, ano, mes, dia_semana,
        lag_7, lag_14, lag_30, lag_365, lag_730, alvo
      FROM `pdm-ceasa.silver.dados_treino`
      WHERE data >= '2026-01-01'
    )
  )
),

silver_arima AS (
  SELECT
    'silver' AS camada,
    'serie_arima' AS modelo,
    CAST(NULL AS FLOAT64) AS r2,
    CAST(NULL AS FLOAT64) AS mae,
    CAST(NULL AS FLOAT64) AS mse,
    CAST(NULL AS FLOAT64) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo,
    CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo,
    CAST(NULL AS INT64) AS n_obs_demo,
    'sem particao de teste - bloco formal nulo; avaliado nas 3 datas da demo; features incluem 5 lags - a comparacao com a bronze mede limpeza e engenharia de features somadas' AS observacao
)

SELECT * FROM bronze_linear
UNION ALL SELECT * FROM bronze_arvore
UNION ALL SELECT * FROM bronze_arima
UNION ALL SELECT * FROM silver_linear
UNION ALL SELECT * FROM silver_arvore
UNION ALL SELECT * FROM silver_arima;
