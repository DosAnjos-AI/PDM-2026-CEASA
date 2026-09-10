-- Treino do ARIMA_PLUS sobre gold.analitica_mensal (nao usa treino_mensal,
-- mesmo motivo do par semanal: o ARIMA modela a defasagem internamente).
-- analitica_mensal so tem ano/mes, sem coluna de data continua -- a data de
-- treino e construida como DATE(ano, mes, 1) (primeiro dia do mes), sem
-- alterar a tabela de origem.
--
-- time_series_id_col = ['produto', 'classe']: mesma serie por combinacao
-- usada no par semanal e na Silver.
-- auto_arima=TRUE, data_frequency='AUTO_FREQUENCY': gold.analitica_mensal
-- tambem tem buracos reais por construcao (vaos medios de 3 a 6 meses sem
-- linha nenhuma, ver sql/construir_tabelas/gold/02_analitica_mensal.sql) --
-- grade irregular, frequencia inferida reportada em
-- sql/consultas/gold/11_avaliacao_serie_arima_gold.sql; divergencia e
-- achado, nao corrigida aqui.
-- holiday_region='BR', decompose_time_series=TRUE: mesma configuracao da
-- Silver e do par semanal.
--
-- Sem particao de teste: mesma decisao do par semanal.
--
-- Horizonte -- medido antes do treino: gold.analitica_mensal tem 210 pares
-- (produto, classe). Consulta exploratoria (nao persistida) mostrou: 184
-- series ativas (ultima observacao real em 2025 ou depois), pior caso entre
-- elas precisando de 18 meses para alcancar 2026-09-04 a partir da propria
-- ultima observacao; as 26 series restantes pararam antes de 2025 (pior
-- caso: ultima observacao real em 2018-02-01, precisando de 103 meses --
-- descontinuadas). horizon=24 cobre as 184 series ativas com folga (18 + 6
-- meses); as 26 descontinuadas nao alcancam 2026-09-04 com nenhum horizonte
-- razoavel -- achado a reportar, nao corrigido. Cobertura real por serie
-- confirmada apos o treino em
-- sql/consultas/gold/12_forecast_serie_arima_gold.sql.
-- horizon conta passos mensais. ML.FORECAST nao herda o horizonte do treino
-- e nao aceita horizon maior que o definido aqui -- mesma restricao do par
-- semanal e da Silver.
--
-- Regra do repositorio: script de treino nao se reexecuta por rotina.
-- CREATE OR REPLACE MODEL retreina ao rodar; para validar sintaxe sem
-- treinar, usar "bq query --dry_run --use_legacy_sql=false < este_arquivo".

CREATE OR REPLACE MODEL `pdm-ceasa.gold.modelo_serie_arima_mensal`
OPTIONS (
  model_type = 'ARIMA_PLUS',
  time_series_timestamp_col = 'data_inicio_mes',
  time_series_data_col = 'media_preco_comum',
  time_series_id_col = ['produto', 'classe'],
  auto_arima = TRUE,
  data_frequency = 'AUTO_FREQUENCY',
  holiday_region = 'BR',
  decompose_time_series = TRUE,
  horizon = 24
) AS
SELECT
  DATE(ano, mes, 1) AS data_inicio_mes,
  produto,
  classe,
  media_preco_comum
FROM `pdm-ceasa.gold.analitica_mensal`;
