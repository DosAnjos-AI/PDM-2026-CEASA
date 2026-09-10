-- Treino do ARIMA_PLUS sobre gold.analitica_semanal (nao usa treino_semanal:
-- o ARIMA modela a defasagem internamente, os lags seriam redundantes e o
-- formato da tabela de features nao serve para serie temporal).
--
-- time_series_id_col = ['produto', 'classe']: uma serie por combinacao
-- (produto, classe), mesma sintaxe ja validada em
-- sql/modelo/silver/03_modelo_serie_arima.sql.
--
-- auto_arima=TRUE, data_frequency='AUTO_FREQUENCY': selecao automatica,
-- sem varredura manual. gold.analitica_semanal tem buracos reais por
-- construcao -- a regra de interpolacao (sql/construir_tabelas/gold/
-- 01_analitica_semanal.sql) deixa vaos medios (5 a 26 semanas) sem linha
-- nenhuma, entao a grade NAO e continua. AUTO_FREQUENCY vai inferir a
-- frequencia sobre essa grade irregular -- resultado reportado em
-- sql/consultas/gold/11_avaliacao_serie_arima_gold.sql; se divergir de
-- semanal (ex.: sair como algo maior por causa de um vao), e achado, nao
-- corrigido aqui (mesmo caso ja visto na Silver: uma serie extrapolou ate
-- 2072-05-14 porque o passo inferido foi de anos).
-- holiday_region='BR', decompose_time_series=TRUE: mesma configuracao da
-- Silver.
--
-- Sem particao de teste: decisao registrada no inventario -- avaliacao via
-- ML.ARIMA_EVALUATE e previsao ao vivo, nao metrica de teste.
--
-- Horizonte -- medido antes do treino, nao suposto:
-- gold.analitica_semanal tem 210 pares (produto, classe). Consulta
-- exploratoria (nao persistida) mostrou: 184 series com ultima observacao
-- real em 2025 ou depois ("ativas"), pior caso entre elas precisando de 78
-- semanas para alcancar 2026-09-04 a partir da propria ultima observacao;
-- as 26 series restantes pararam de reportar antes de 2025 (pior caso:
-- ultima observacao real em 2018-02-05, precisando de 447 semanas -- series
-- de produto/classe efetivamente descontinuadas). horizon=90 cobre as 184
-- series ativas com folga (78 + 12 semanas); as 26 descontinuadas NAO
-- alcancam 2026-09-04 com nenhum horizonte razoavel -- achado a reportar,
-- nao corrigido inflando o horizonte para um caso que nao volta a ter
-- pregao. Cobertura real por serie confirmada apos o treino em
-- sql/consultas/gold/12_forecast_serie_arima_gold.sql.
-- horizon conta passos semanais, nao dias corridos. ML.FORECAST nao herda
-- o horizonte do treino (default proprio da funcao = 3, achado ja
-- registrado na Silver) e nao aceita horizon maior que o definido aqui --
-- por isso o valor precisa estar decidido antes deste treino.
--
-- Regra do repositorio: script de treino nao se reexecuta por rotina.
-- CREATE OR REPLACE MODEL retreina ao rodar; para validar sintaxe sem
-- treinar, usar "bq query --dry_run --use_legacy_sql=false < este_arquivo".

CREATE OR REPLACE MODEL `pdm-ceasa.gold.modelo_serie_arima_semanal`
OPTIONS (
  model_type = 'ARIMA_PLUS',
  time_series_timestamp_col = 'data_inicio_semana',
  time_series_data_col = 'media_preco_comum',
  time_series_id_col = ['produto', 'classe'],
  auto_arima = TRUE,
  data_frequency = 'AUTO_FREQUENCY',
  holiday_region = 'BR',
  decompose_time_series = TRUE,
  horizon = 90
) AS
SELECT
  data_inicio_semana,
  produto,
  classe,
  media_preco_comum
FROM `pdm-ceasa.gold.analitica_semanal`;
