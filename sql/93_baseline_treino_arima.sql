-- Bloco 11: retreino do ARIMA_PLUS sem split, com horizonte corrigido.
--
-- Sem partição de teste: o ARIMA vale pela previsão ao vivo na apresentação,
-- não por métrica de teste (decisão registrada no Bloco 11). Os dois modelos
-- de regressão continuam com split — este script não os toca.
-- Treina com toda a série disponível, até a data máxima da Bronze
-- (2026-08-28 na execução deste script), sem filtro de data.
--
-- Horizonte: o objetivo é projetar ~7 dias corridos à frente, mas horizon
-- conta PASSOS (pregões), não dias corridos. Medido sobre toda a Bronze,
-- a série tem gap médio de ~1,76 dia entre pregões (~4 pregões por semana),
-- então 1 pregão ~= 7/4 = 1,75 dia e 4 pregões ~= 7 dias corridos. Por isso
-- horizon = 4 (equivalência aproximada, não exata: pregões não caem em
-- intervalos regulares -- ver prova de execução no relatório do Bloco 11
-- para o alcance real em dias corridos, série a série).
--
-- time_series_id_col identifica a série combinando produto e classe em
-- uma única coluna, no formato PRODUTO|CLASSE.
--
-- CREATE OR REPLACE MODEL: idempotente, reexecutar substitui o modelo anterior.

CREATE OR REPLACE MODEL `pdm-ceasa.baseline.modelo_serie_arima`
OPTIONS (
  model_type = 'ARIMA_PLUS',
  time_series_timestamp_col = 'data',
  time_series_data_col = 'preco_comum',
  time_series_id_col = 'serie_id',
  horizon = 4,
  auto_arima = TRUE
) AS
SELECT
  data,
  CONCAT(produto, '|', CAST(classe AS STRING)) AS serie_id,
  preco_comum
FROM `pdm-ceasa.bronze.cotacoes`;
