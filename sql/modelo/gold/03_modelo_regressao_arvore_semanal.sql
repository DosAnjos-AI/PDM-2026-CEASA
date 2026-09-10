-- Treino do modelo de arvore boosted sobre gold.treino_semanal.
-- Entrada: produto, classe, grupo, isoyear, isoweek, lag_1s, lag_2s,
-- lag_4s, lag_52s, lag_104s -> alvo -- vetor identico ao usado em
-- sql/modelo/gold/01_modelo_regressao_linear_semanal.sql, sem nenhuma
-- alteracao. Manter o vetor identico e o ponto: vetor diferente faria a
-- comparacao entre os dois modelos medir o vetor, nao o algoritmo.
-- data_inicio_semana NAO entra no SELECT de features -- so aparece no
-- WHERE, para o corte temporal do split.
-- Split temporal: treino usa data_inicio_semana <= 2025-12-31 (54.958
-- linhas); a particao de teste (data_inicio_semana > 2025-12-31, 5.426
-- linhas) fica de fora e e avaliada em
-- sql/consultas/gold/08_avaliacao_regressao_arvore_gold.sql. Mesmo corte
-- temporal da linear.
--
-- Sem regularizacao elastic net: L1_REG/L2_REG nao se aplicam a
-- BOOSTED_TREE_REGRESSOR.
-- Sem varredura de hiperparametros. MAX_ITERATIONS e EARLY_STOP ficam no
-- default do BigQuery ML (MAX_ITERATIONS=20, EARLY_STOP=TRUE) -- valores
-- nao alterados, declarados aqui e no relatorio por exigencia do prompt,
-- nao por terem sido ajustados.
-- ENABLE_GLOBAL_EXPLAIN=TRUE: importancia das features e material de
-- relatorio e de slide.
--
-- Alvo e media de preco da semana seguinte (media de periodo), nao preco de
-- um dia -- mesma ressalva de escala do modelo linear semanal.
--
-- Regra do repositorio: script de treino nao se reexecuta por rotina.
-- CREATE OR REPLACE MODEL retreina ao rodar; para validar sintaxe sem
-- treinar, usar "bq query --dry_run --use_legacy_sql=false < este_arquivo".

CREATE OR REPLACE MODEL `pdm-ceasa.gold.modelo_regressao_arvore_semanal`
OPTIONS (
  model_type = 'BOOSTED_TREE_REGRESSOR',
  input_label_cols = ['alvo'],
  enable_global_explain = TRUE
) AS
SELECT
  produto,
  classe,
  grupo,
  isoyear,
  isoweek,
  lag_1s,
  lag_2s,
  lag_4s,
  lag_52s,
  lag_104s,
  alvo
FROM `pdm-ceasa.gold.treino_semanal`
WHERE data_inicio_semana <= '2025-12-31';
