-- Avaliacao dos modelos gold.modelo_regressao_linear_semanal e
-- gold.modelo_regressao_linear_mensal nas respectivas particoes de teste
-- (nunca vistas no treino): data_inicio_semana > 2025-12-31 para o semanal,
-- DATE(ano, mes, 1) > 2025-12-31 para o mensal.
-- Faz: ML.EVALUATE + RMSE calculado (RMSE nao e retornado nativamente por
-- ML.EVALUATE), um bloco por granularidade.
-- Nao faz: nao persiste nenhuma tabela, nao retreina nenhum modelo.
--
-- Ressalva obrigatoria de escala: o alvo aqui e media de preco do periodo
-- (semana/mes seguinte), nao preco de um dia -- o erro tende a ser menor
-- que o das camadas bronze/silver por construcao da metrica (media suaviza
-- variacao), nao por merito do modelo. Ver observacao gravada em
-- pdm-ceasa.metricas.comparacao_modelos para as seis linhas gold.

-- Semanal
SELECT
  'semanal' AS granularidade,
  r2_score,
  mean_absolute_error,
  mean_squared_error,
  SQRT(mean_squared_error) AS rmse
FROM ML.EVALUATE(
  MODEL `pdm-ceasa.gold.modelo_regressao_linear_semanal`,
  (
    SELECT
      produto, classe, grupo, isoyear, isoweek,
      lag_1s, lag_2s, lag_4s, lag_52s, lag_104s, alvo
    FROM `pdm-ceasa.gold.treino_semanal`
    WHERE data_inicio_semana > '2025-12-31'
  )
);

-- Mensal
SELECT
  'mensal' AS granularidade,
  r2_score,
  mean_absolute_error,
  mean_squared_error,
  SQRT(mean_squared_error) AS rmse
FROM ML.EVALUATE(
  MODEL `pdm-ceasa.gold.modelo_regressao_linear_mensal`,
  (
    SELECT
      produto, classe, grupo, ano, mes,
      lag_1m, lag_12m, lag_24m, alvo
    FROM `pdm-ceasa.gold.treino_mensal`
    WHERE DATE(ano, mes, 1) > '2025-12-31'
  )
);
