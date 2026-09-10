-- Treino do modelo de arvore boosted sobre gold.treino_mensal.
-- Entrada: produto, classe, grupo, ano, mes, lag_1m, lag_12m, lag_24m ->
-- alvo -- vetor identico ao usado em
-- sql/modelo/gold/02_modelo_regressao_linear_mensal.sql, sem nenhuma
-- alteracao. Mesmo motivo do par semanal: vetor diferente faria a
-- comparacao medir o vetor, nao o algoritmo.
-- Split temporal: treino usa DATE(ano, mes, 1) <= 2025-12-31 (13.032
-- linhas); a particao de teste (DATE(ano, mes, 1) > 2025-12-31, 1.167
-- linhas) fica de fora e e avaliada em
-- sql/consultas/gold/08_avaliacao_regressao_arvore_gold.sql. Mesmo corte
-- temporal da linear mensal.
--
-- Sem regularizacao elastic net: nao se aplica a BOOSTED_TREE_REGRESSOR.
-- Sem varredura de hiperparametros. MAX_ITERATIONS e EARLY_STOP ficam no
-- default do BigQuery ML (MAX_ITERATIONS=20, EARLY_STOP=TRUE) -- declarados
-- aqui e no relatorio, nao ajustados.
-- ENABLE_GLOBAL_EXPLAIN=TRUE: importancia das features e material de
-- relatorio e de slide.
--
-- Alvo e media de preco do mes seguinte (media de periodo), nao preco de um
-- dia -- mesma ressalva de escala do modelo linear mensal.
--
-- Regra do repositorio: script de treino nao se reexecuta por rotina.
-- CREATE OR REPLACE MODEL retreina ao rodar; para validar sintaxe sem
-- treinar, usar "bq query --dry_run --use_legacy_sql=false < este_arquivo".

CREATE OR REPLACE MODEL `pdm-ceasa.gold.modelo_regressao_arvore_mensal`
OPTIONS (
  model_type = 'BOOSTED_TREE_REGRESSOR',
  input_label_cols = ['alvo'],
  enable_global_explain = TRUE
) AS
SELECT
  produto,
  classe,
  grupo,
  ano,
  mes,
  lag_1m,
  lag_12m,
  lag_24m,
  alvo
FROM `pdm-ceasa.gold.treino_mensal`
WHERE DATE(ano, mes, 1) <= '2025-12-31';
