-- Treino do modelo de regressao linear com regularizacao elastic net
-- sobre silver.dados_treino.
-- Entrada: produto, classe, grupo, ano, mes, dia_semana, lag_7, lag_14,
-- lag_30, lag_365, lag_730. data NAO entra no SELECT de features -- so
-- aparece no WHERE, para o corte temporal do split.
-- Split temporal: treino usa data <= 2025-12-31; a particao de teste
-- (data >= 2026-01-01) fica de fora e e avaliada em
-- sql/consultas/silver/09_avaliacao_regressao_linear.sql. Corte por WHERE,
-- equivalente a DATA_SPLIT_METHOD='CUSTOM' sem exigir coluna de split --
-- mesmo padrao ja usado em sql/modelo/bronze/02_baseline_treino_linear.sql.
--
-- L1_REG=1.0 e L2_REG=1.0: elastic net com pesos iguais, valores moderados
-- escolhidos sem varredura de hiperparametros (fora do escopo desta
-- tarefa). Justificativa: os 5 lags sao fortemente correlacionados entre
-- si e produto gera 141 colunas em one-hot -- L1 empurra para esparsidade
-- nessas colunas, L2 ataca a colinearidade entre os lags.
--
-- CALCULATE_P_VALUES=FALSE: nao precisamos de significancia estatistica
-- por coeficiente para este entregavel.
-- ENABLE_GLOBAL_EXPLAIN=TRUE: peso das features e material de relatorio
-- e de slide.
--
-- Regra do repositorio: script de treino nao se reexecuta por rotina.
-- CREATE OR REPLACE MODEL retreina ao rodar; para validar sintaxe sem
-- treinar, usar "bq query --dry_run --use_legacy_sql=false < este_arquivo".
-- LINEAR_REG tem inicializacao estocastica -- reexecutar sem mudar o
-- desenho do modelo nao reproduz a metrica exata; variacao sem mudanca de
-- desenho e ruido do treino, nao regressao do modelo.

CREATE OR REPLACE MODEL `pdm-ceasa.silver.modelo_regressao_linear`
OPTIONS (
  model_type = 'LINEAR_REG',
  input_label_cols = ['alvo'],
  l1_reg = 1.0,
  l2_reg = 1.0,
  calculate_p_values = FALSE,
  enable_global_explain = TRUE
) AS
SELECT
  produto,
  classe,
  grupo,
  ano,
  mes,
  dia_semana,
  lag_7,
  lag_14,
  lag_30,
  lag_365,
  lag_730,
  alvo
FROM `pdm-ceasa.silver.dados_treino`
WHERE data <= '2025-12-31';
