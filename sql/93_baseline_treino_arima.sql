-- Bloco 10: treino do modelo de série temporal ARIMA_PLUS sobre a Bronze crua.
-- Fonte diferente dos dois modelos anteriores: aqui a entrada é a própria
-- série histórica de preco_comum por (produto, classe) — é isso que um
-- modelo ARIMA consome, não é feature derivada de preço proibida (o alvo
-- de 7 dias não é calculado aqui; quem projeta o horizonte é o próprio
-- ARIMA via horizon).
-- time_series_id_col identifica a série combinando produto e classe em
-- uma única coluna (BQML exige coluna única para o id da série).
-- Mesmo split temporal: treino usa só data <= 2025-12-31.
-- horizon = 7: projeta 7 passos após o fim da série treinada.
--
-- CREATE OR REPLACE MODEL: idempotente, reexecutar substitui o modelo anterior.

CREATE OR REPLACE MODEL `pdm-ceasa.baseline.modelo_serie_arima`
OPTIONS (
  model_type = 'ARIMA_PLUS',
  time_series_timestamp_col = 'data',
  time_series_data_col = 'preco_comum',
  time_series_id_col = 'serie_id',
  horizon = 7,
  auto_arima = TRUE
) AS
SELECT
  data,
  CONCAT(produto, '|', CAST(classe AS STRING)) AS serie_id,
  preco_comum
FROM `pdm-ceasa.bronze.cotacoes`
WHERE data <= '2025-12-31';
