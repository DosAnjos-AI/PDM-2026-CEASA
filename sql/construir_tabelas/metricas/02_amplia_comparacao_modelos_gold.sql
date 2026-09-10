-- Amplia pdm-ceasa.metricas.comparacao_modelos com as 6 linhas dos modelos
-- gold (linear, arvore e ARIMA, semanal e mensal), totalizando 12 linhas.
--
-- Faz:
-- 1) ALTER TABLE ADD COLUMN IF NOT EXISTS granularidade STRING -- nao existe
--    na tabela original (bronze/silver so preveem preco de um dia).
-- 2) UPDATE preenchendo granularidade='diario' nas linhas que ainda
--    estiverem com granularidade NULL -- so afeta as 6 linhas originais de
--    bronze/silver, e so na primeira execucao (idempotente: reexecutar nao
--    muda linha ja preenchida).
-- 3) DELETE das linhas camada='gold' seguido de INSERT das 6 linhas novas --
--    torna o bloco gold idempotente sem tocar nas 6 linhas de bronze/silver.
--    r2/mae/mse/rmse das lineares e arvores vem de ML.EVALUATE ao vivo sobre
--    os modelos ja treinados (nao retreina nada); ARIMA fica NULL, sem
--    particao de teste, mesma decisao ja usada para bronze/silver.
--
-- Nao faz: nao contem CREATE MODEL nem CREATE OR REPLACE MODEL. Nao altera
-- nenhuma das 6 linhas de bronze/silver (nem os 4 valores formais, nem o
-- bloco demo ja preenchido) -- nenhum CREATE OR REPLACE TABLE neste script.
-- Nao preenche o bloco demo (mae_demo/mse_demo/rmse_demo/n_obs_demo) das 6
-- linhas gold -- fica NULL aqui, preenchido por
-- sql/consultas/metricas/03_previsoes_demo_gold.sql +
-- scripts/metricas_demo_gold.py, mesmo padrao ja usado para bronze/silver.
--
-- Ressalva obrigatoria de escala (prompt, secao 7.1), gravada em
-- observacao nas 6 linhas gold: o alvo da Gold e media de periodo
-- (semanal/mensal), nao preco de um dia como em bronze/silver -- o erro e
-- menor por construcao da metrica (media suaviza variacao), nao por merito
-- do modelo, e a comparacao entre camadas mede limpeza, engenharia de
-- features e granularidade somadas, nao um efeito isolado.
--
-- Esperado apos rodar: 12 linhas totais, as 4 linhas do bloco formal de
-- bronze/silver inalteradas (conferir com
-- sql/consultas/metricas/04_comparacao_modelos_check_gold.sql, comparando
-- com o snapshot tirado antes desta ampliacao).

ALTER TABLE `pdm-ceasa.metricas.comparacao_modelos`
  ADD COLUMN IF NOT EXISTS granularidade STRING;

UPDATE `pdm-ceasa.metricas.comparacao_modelos`
SET granularidade = 'diario'
WHERE granularidade IS NULL;

DELETE FROM `pdm-ceasa.metricas.comparacao_modelos`
WHERE camada = 'gold';

INSERT INTO `pdm-ceasa.metricas.comparacao_modelos`
(camada, modelo, granularidade, r2, mae, mse, rmse, mae_demo, mse_demo, rmse_demo, n_obs_demo, observacao)

WITH gold_linear_semanal AS (
  SELECT
    'gold' AS camada, 'regressao_linear' AS modelo, 'semanal' AS granularidade,
    r2_score AS r2, mean_absolute_error AS mae, mean_squared_error AS mse,
    SQRT(mean_squared_error) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo, CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo, CAST(NULL AS INT64) AS n_obs_demo,
    'alvo e media de periodo (semanal/mensal), nao preco diario - o erro e menor por construcao, ja que media suaviza a variacao; nao e comparavel em escala com as camadas bronze e silver, que preveem preco de um dia. Features incluem lags de periodo; a comparacao entre camadas mede limpeza, engenharia de features e granularidade somadas. Elastic net, L1=1.0 e L2=1.0, mesmos valores da Silver, para comparabilidade.' AS observacao
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.gold.modelo_regressao_linear_semanal`,
    (
      SELECT produto, classe, grupo, isoyear, isoweek, lag_1s, lag_2s, lag_4s, lag_52s, lag_104s, alvo
      FROM `pdm-ceasa.gold.treino_semanal`
      WHERE data_inicio_semana > '2025-12-31'
    )
  )
),

gold_linear_mensal AS (
  SELECT
    'gold' AS camada, 'regressao_linear' AS modelo, 'mensal' AS granularidade,
    r2_score AS r2, mean_absolute_error AS mae, mean_squared_error AS mse,
    SQRT(mean_squared_error) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo, CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo, CAST(NULL AS INT64) AS n_obs_demo,
    'alvo e media de periodo (semanal/mensal), nao preco diario - o erro e menor por construcao, ja que media suaviza a variacao; nao e comparavel em escala com as camadas bronze e silver, que preveem preco de um dia. Features incluem lags de periodo; a comparacao entre camadas mede limpeza, engenharia de features e granularidade somadas. Elastic net, L1=1.0 e L2=1.0, mesmos valores da Silver, para comparabilidade.' AS observacao
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.gold.modelo_regressao_linear_mensal`,
    (
      SELECT produto, classe, grupo, ano, mes, lag_1m, lag_12m, lag_24m, alvo
      FROM `pdm-ceasa.gold.treino_mensal`
      WHERE DATE(ano, mes, 1) > '2025-12-31'
    )
  )
),

gold_arvore_semanal AS (
  SELECT
    'gold' AS camada, 'regressao_arvore' AS modelo, 'semanal' AS granularidade,
    r2_score AS r2, mean_absolute_error AS mae, mean_squared_error AS mse,
    SQRT(mean_squared_error) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo, CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo, CAST(NULL AS INT64) AS n_obs_demo,
    'alvo e media de periodo (semanal/mensal), nao preco diario - o erro e menor por construcao, ja que media suaviza a variacao; nao e comparavel em escala com as camadas bronze e silver, que preveem preco de um dia. Features incluem lags de periodo; a comparacao entre camadas mede limpeza, engenharia de features e granularidade somadas. MAX_ITERATIONS=20 e EARLY_STOP=TRUE, defaults do BigQuery ML, sem varredura de hiperparametros.' AS observacao
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.gold.modelo_regressao_arvore_semanal`,
    (
      SELECT produto, classe, grupo, isoyear, isoweek, lag_1s, lag_2s, lag_4s, lag_52s, lag_104s, alvo
      FROM `pdm-ceasa.gold.treino_semanal`
      WHERE data_inicio_semana > '2025-12-31'
    )
  )
),

gold_arvore_mensal AS (
  SELECT
    'gold' AS camada, 'regressao_arvore' AS modelo, 'mensal' AS granularidade,
    r2_score AS r2, mean_absolute_error AS mae, mean_squared_error AS mse,
    SQRT(mean_squared_error) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo, CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo, CAST(NULL AS INT64) AS n_obs_demo,
    'alvo e media de periodo (semanal/mensal), nao preco diario - o erro e menor por construcao, ja que media suaviza a variacao; nao e comparavel em escala com as camadas bronze e silver, que preveem preco de um dia. Features incluem lags de periodo; a comparacao entre camadas mede limpeza, engenharia de features e granularidade somadas. MAX_ITERATIONS=20 e EARLY_STOP=TRUE, defaults do BigQuery ML, sem varredura de hiperparametros.' AS observacao
  FROM ML.EVALUATE(
    MODEL `pdm-ceasa.gold.modelo_regressao_arvore_mensal`,
    (
      SELECT produto, classe, grupo, ano, mes, lag_1m, lag_12m, lag_24m, alvo
      FROM `pdm-ceasa.gold.treino_mensal`
      WHERE DATE(ano, mes, 1) > '2025-12-31'
    )
  )
),

gold_arima_semanal AS (
  SELECT
    'gold' AS camada, 'serie_arima' AS modelo, 'semanal' AS granularidade,
    CAST(NULL AS FLOAT64) AS r2, CAST(NULL AS FLOAT64) AS mae,
    CAST(NULL AS FLOAT64) AS mse, CAST(NULL AS FLOAT64) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo, CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo, CAST(NULL AS INT64) AS n_obs_demo,
    'alvo e media de periodo (semanal/mensal), nao preco diario - o erro e menor por construcao, ja que media suaviza a variacao; nao e comparavel em escala com as camadas bronze e silver, que preveem preco de um dia. Features incluem lags de periodo; a comparacao entre camadas mede limpeza, engenharia de features e granularidade somadas. Sem particao de teste - avaliado apenas pelas 3 datas da demo. horizon=90 semanas; AUTO_FREQUENCY inferiu passo semanal (7 dias) em 183 de 184 series avaliadas - 1 serie (banana_maca, classe 2) inferiu passo de ~105 dias, estendendo a previsao ate 2049-09-27 (achado registrado, nao corrigido, mesmo padrao ja visto na Silver). 26 dos 210 pares (produto, classe) de analitica_semanal nao foram avaliados pelo AUTO_ARIMA (series paradas antes de 2025).' AS observacao
),

gold_arima_mensal AS (
  SELECT
    'gold' AS camada, 'serie_arima' AS modelo, 'mensal' AS granularidade,
    CAST(NULL AS FLOAT64) AS r2, CAST(NULL AS FLOAT64) AS mae,
    CAST(NULL AS FLOAT64) AS mse, CAST(NULL AS FLOAT64) AS rmse,
    CAST(NULL AS FLOAT64) AS mae_demo, CAST(NULL AS FLOAT64) AS mse_demo,
    CAST(NULL AS FLOAT64) AS rmse_demo, CAST(NULL AS INT64) AS n_obs_demo,
    'alvo e media de periodo (semanal/mensal), nao preco diario - o erro e menor por construcao, ja que media suaviza a variacao; nao e comparavel em escala com as camadas bronze e silver, que preveem preco de um dia. Features incluem lags de periodo; a comparacao entre camadas mede limpeza, engenharia de features e granularidade somadas. Sem particao de teste - avaliado apenas pelas 3 datas da demo. horizon=24 meses; AUTO_FREQUENCY inferiu passo mensal (30 dias) em todas as 183 series avaliadas, sem anomalia. 27 dos 210 pares (produto, classe) de analitica_mensal nao foram avaliados pelo AUTO_ARIMA (series paradas antes de 2025).' AS observacao
)

SELECT * FROM gold_linear_semanal
UNION ALL SELECT * FROM gold_linear_mensal
UNION ALL SELECT * FROM gold_arvore_semanal
UNION ALL SELECT * FROM gold_arvore_mensal
UNION ALL SELECT * FROM gold_arima_semanal
UNION ALL SELECT * FROM gold_arima_mensal;
