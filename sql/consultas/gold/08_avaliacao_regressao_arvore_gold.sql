-- Avaliacao dos modelos gold.modelo_regressao_arvore_semanal e
-- gold.modelo_regressao_arvore_mensal nas respectivas particoes de teste --
-- mesmo padrao de sql/consultas/gold/06_avaliacao_regressao_linear_gold.sql,
-- mesma ressalva de escala (alvo = media de periodo, nao preco de um dia).
-- Nao faz: nao persiste nenhuma tabela, nao retreina nenhum modelo.

-- Semanal
SELECT
  'semanal' AS granularidade,
  r2_score,
  mean_absolute_error,
  mean_squared_error,
  SQRT(mean_squared_error) AS rmse
FROM ML.EVALUATE(
  MODEL `pdm-ceasa.gold.modelo_regressao_arvore_semanal`,
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
  MODEL `pdm-ceasa.gold.modelo_regressao_arvore_mensal`,
  (
    SELECT
      produto, classe, grupo, ano, mes,
      lag_1m, lag_12m, lag_24m, alvo
    FROM `pdm-ceasa.gold.treino_mensal`
    WHERE DATE(ano, mes, 1) > '2025-12-31'
  )
);
