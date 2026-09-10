-- Avaliacao do modelo silver.modelo_serie_arima via ML.ARIMA_EVALUATE.
-- Faz: reporta, por serie (produto, classe), a ordem (p,d,q) escolhida pelo
-- AUTO_ARIMA, o AIC, se ha sazonalidade detectada, e a frequencia de dados
-- usada no treino -- item de atencao obrigatorio do prompt, porque a serie
-- tem lacunas por construcao (sem pregao aos domingos, cobertura entre 92%
-- e 99% conforme o produto) e a frequencia detectada pode sair diferente
-- do esperado.
-- Nao faz: nao persiste nenhuma tabela, nao ha ML.EVALUATE com particao de
-- teste -- decisao registrada de nao criar particao para o ARIMA.
--
-- Esperado: uma linha por serie (produto, classe) que o AUTO_ARIMA
-- conseguiu ajustar. Se o numero de linhas for menor que as series
-- distintas em silver.cotacoes, a segunda consulta abaixo quantifica a
-- diferenca -- series que o ARIMA nao conseguiu modelar sao achado, nao
-- ruido.

SELECT
  produto,
  classe,
  non_seasonal_p,
  non_seasonal_d,
  non_seasonal_q,
  has_drift,
  has_holiday_effect,
  has_spikes_and_dips,
  has_step_changes,
  seasonal_periods,
  aic,
  variance,
  error_message
FROM ML.ARIMA_EVALUATE(MODEL `pdm-ceasa.silver.modelo_serie_arima`)
ORDER BY produto, classe;

-- Quantas series a silver.cotacoes tem versus quantas o ARIMA conseguiu
-- avaliar (com e sem erro registrado em error_message).
WITH series_fonte AS (
  SELECT COUNT(DISTINCT CONCAT(produto, '|', CAST(classe AS STRING))) AS total_series
  FROM `pdm-ceasa.silver.cotacoes`
),
series_avaliadas AS (
  SELECT
    COUNT(*) AS total_avaliadas,
    COUNTIF(error_message IS NOT NULL) AS com_erro,
    COUNTIF(error_message IS NULL) AS sem_erro
  FROM ML.ARIMA_EVALUATE(MODEL `pdm-ceasa.silver.modelo_serie_arima`)
)
SELECT * FROM series_fonte, series_avaliadas;
