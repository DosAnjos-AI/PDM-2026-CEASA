-- Treino do ARIMA_PLUS sobre silver.cotacoes (nao usa dados_treino: o ARIMA
-- modela a defasagem internamente, os lags seriam redundantes e o formato
-- da tabela de features nao serve para serie temporal).
--
-- time_series_id_col = ['produto', 'classe']: uma serie por combinacao
-- (produto, classe), sintaxe de array validada por dry run antes deste
-- treino -- BigQuery ML aceita mais de uma coluna de identificacao de
-- serie diretamente, sem precisar concatenar em uma coluna auxiliar (ao
-- contrario do baseline sobre a bronze, que usa CONCAT(produto, classe)).
--
-- auto_arima=TRUE: selecao de (p,d,q) automatica, sem varredura manual.
-- data_frequency='AUTO_FREQUENCY': a serie tem lacunas por construcao (nao
-- ha pregao todos os dias, domingos nao existem, cobertura varia entre 92%
-- e 99% conforme o produto) -- a frequencia detectada e reportada em
-- sql/consultas/silver/13_avaliacao_serie_arima.sql via ML.ARIMA_EVALUATE;
-- se vier diferente do esperado (ex.: WEEKLY), e achado, nao detalhe.
-- holiday_region='BR': pregao de CEASA e afetado por feriado nacional.
-- decompose_time_series=TRUE: expoe tendencia e sazonalidade separadas.
--
-- Sem particao de teste: decisao registrada no inventario -- o ARIMA vale
-- pela previsao ao vivo na apresentacao, nao pela metrica de teste. Treina
-- com a serie inteira, sem filtro de data.
--
-- Horizonte: silver.cotacoes termina em 2026-08-28 na agregacao da tabela
-- inteira, mas ML.FORECAST projeta a partir da ULTIMA data observada de
-- CADA serie (produto, classe) -- nao da data maxima global. Boa parte dos
-- 141 produtos da classe 1 (a classe principal) tem pregao proximo dessa
-- data, mas ha excecoes com defasagem real: o pior caso medido,
-- "abobora_japonesa_(kabutia)", tem ultimo pregao em 2026-07-21 (38 dias
-- antes de 2026-08-28) e passo de forecast de ~1 dia. Testado
-- empiricamente com horizon=14: cobriu so 119 dos 141 produtos da classe 1
-- ate 2026-09-04, os outros 22 ficaram aquem por causa dessa defasagem
-- por produto -- achado registrado no relatorio, nao "numero batendo por
-- ajuste".
-- horizon conta passos (pregoes), nao dias corridos. horizon=60 escolhido
-- para cobrir com folga ate ~2026-09-11 mesmo no pior caso medido; a data
-- final realmente alcancada por serie e confirmada apos o treino em
-- sql/consultas/silver/14_forecast_serie_arima.sql e declarada no
-- relatorio. ML.FORECAST nao aceita horizon maior que o definido aqui no
-- treino -- confirmado por erro explicito do BigQuery ao tentar; por isso
-- o valor precisa ser definido com folga desde o treino, nao ajustado so
-- na chamada de ML.FORECAST.
--
-- Regra do repositorio: script de treino nao se reexecuta por rotina.
-- CREATE OR REPLACE MODEL retreina ao rodar; para validar sintaxe sem
-- treinar, usar "bq query --dry_run --use_legacy_sql=false < este_arquivo".

CREATE OR REPLACE MODEL `pdm-ceasa.silver.modelo_serie_arima`
OPTIONS (
  model_type = 'ARIMA_PLUS',
  time_series_timestamp_col = 'data',
  time_series_data_col = 'preco_comum',
  time_series_id_col = ['produto', 'classe'],
  auto_arima = TRUE,
  data_frequency = 'AUTO_FREQUENCY',
  holiday_region = 'BR',
  decompose_time_series = TRUE,
  horizon = 60
) AS
SELECT
  data,
  produto,
  classe,
  preco_comum
FROM `pdm-ceasa.silver.cotacoes`;
