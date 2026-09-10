-- Previsao do modelo silver.modelo_serie_arima via ML.FORECAST, cobrindo
-- pelo menos ate 2026-09-04 (silver.cotacoes termina em 2026-08-28; horizon
-- do treino = 60).
-- Achado registrado durante o desenvolvimento: ML.FORECAST SEM
-- STRUCT(horizon...) explicito usa o default proprio da funcao (3), nao o
-- horizon do treino -- confirmado empiricamente (rodar sem horizon devolveu
-- so 3 passos por serie). Por isso horizon=60 e passado aqui de forma
-- explicita, replicando o valor do treino. ML.FORECAST tambem nao aceita
-- horizon MAIOR que o definido no treino (erro explicito do BigQuery testado
-- em desenvolvimento) -- os dois valores tem que ficar iguais ou o segundo
-- menor, nunca maior.
-- Faz: lista o forecast completo por serie e uma consulta separada so com
-- a data final realmente alcancada por serie, para declarar no relatorio
-- quantos produtos da classe 1 (a classe principal, 141 produtos) cobriram
-- 2026-09-04 e quais nao cobriram -- defasagem por produto e achado, nao
-- ruido (ver comentario do script de treino).
-- Nao faz: nao persiste nenhuma tabela, nao filtra nenhum produto.
--
-- Nao ha ML.EVALUATE com particao de teste para o ARIMA -- decisao
-- registrada no inventario, nao inventar uma aqui.

SELECT
  produto,
  classe,
  forecast_timestamp,
  forecast_value,
  standard_error,
  confidence_level,
  prediction_interval_lower_bound,
  prediction_interval_upper_bound
FROM ML.FORECAST(
  MODEL `pdm-ceasa.silver.modelo_serie_arima`,
  STRUCT(60 AS horizon, 0.95 AS confidence_level)
)
ORDER BY produto, classe, forecast_timestamp;

-- Data final de previsao alcancada por serie -- confirma se 2026-09-04
-- ficou coberto em todas as series ou se alguma divergiu.
SELECT
  MIN(data_final_serie) AS pior_caso_data_final,
  MAX(data_final_serie) AS melhor_caso_data_final,
  COUNTIF(data_final_serie < '2026-09-04') AS series_abaixo_de_09_04,
  COUNT(*) AS total_series
FROM (
  SELECT
    produto,
    classe,
    MAX(DATE(forecast_timestamp)) AS data_final_serie
  FROM ML.FORECAST(
    MODEL `pdm-ceasa.silver.modelo_serie_arima`,
    STRUCT(60 AS horizon, 0.95 AS confidence_level)
  )
  GROUP BY produto, classe
);
