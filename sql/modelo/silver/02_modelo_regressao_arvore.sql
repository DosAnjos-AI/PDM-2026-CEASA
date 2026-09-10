-- Treino do modelo de arvore boosted sobre silver.dados_treino.
-- Entrada: produto, classe, grupo, ano, mes, dia_semana, lag_7, lag_14,
-- lag_30, lag_365, lag_730 -- vetor identico ao usado em
-- sql/modelo/silver/01_modelo_regressao_linear.sql, sem nenhuma alteracao.
-- Manter o vetor identico e o ponto: se a arvore usasse features diferentes,
-- a comparacao entre os dois modelos deixaria de medir o algoritmo e passaria
-- a medir tambem o vetor. data NAO entra no SELECT de features -- so aparece
-- no WHERE, para o corte temporal do split.
-- Split temporal: treino usa data <= 2025-12-31; a particao de teste
-- (data >= 2026-01-01) fica de fora e e avaliada em
-- sql/consultas/silver/11_avaliacao_regressao_arvore.sql. Mesmo corte
-- temporal da linear -- split aleatorio invalidaria a avaliacao em serie
-- temporal.
--
-- Sem regularizacao elastic net: L1_REG/L2_REG nao se aplicam a
-- BOOSTED_TREE_REGRESSOR.
-- Sem varredura de hiperparametros: nao ha tempo e nao e o objetivo deste
-- treino. MAX_ITERATIONS e EARLY_STOP ficam no default do BigQuery ML
-- (MAX_ITERATIONS=20, EARLY_STOP=TRUE) -- valores nao alterados, declarados
-- aqui e no relatorio por exigencia do prompt, nao por terem sido ajustados.
-- ENABLE_GLOBAL_EXPLAIN=TRUE: importancia das features e material de
-- relatorio e de slide, e permite comparar quais lags a arvore usa contra o
-- que a linear ponderou.
--
-- Esperado: 238.472 linhas de entrada (silver.dados_treino), split
-- 218.505 treino / 19.967 teste -- mesmos numeros da linear, ja conferidos
-- em sql/consultas/silver/08_dados_treino_check.sql. Se a arvore nao
-- reproduzir esse split, o corte temporal foi aplicado de forma diferente
-- e a comparacao entre os dois modelos fica comprometida -- reportar antes
-- de avaliar.
--
-- Regra do repositorio: script de treino nao se reexecuta por rotina.
-- CREATE OR REPLACE MODEL retreina ao rodar; para validar sintaxe sem
-- treinar, usar "bq query --dry_run --use_legacy_sql=false < este_arquivo".

CREATE OR REPLACE MODEL `pdm-ceasa.silver.modelo_regressao_arvore`
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
  dia_semana,
  lag_7,
  lag_14,
  lag_30,
  lag_365,
  lag_730,
  alvo
FROM `pdm-ceasa.silver.dados_treino`
WHERE data <= '2025-12-31';
