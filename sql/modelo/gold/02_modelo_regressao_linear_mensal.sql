-- Treino do modelo de regressao linear com regularizacao elastic net sobre
-- gold.treino_mensal (base mensal da Gold).
-- Entrada: produto, classe, grupo, ano, mes, lag_1m, lag_12m, lag_24m ->
-- alvo. gold.treino_mensal nao tem coluna de data continua (so ano/mes) --
-- o corte temporal do split e feito por DATE(ano, mes, 1), sem adicionar
-- nenhuma coluna nova a tabela nem ao vetor de features.
-- Split temporal: treino usa DATE(ano, mes, 1) <= 2025-12-31 (13.032
-- linhas, conferido antes deste treino); a particao de teste
-- (DATE(ano, mes, 1) > 2025-12-31, 1.167 linhas) fica de fora e e avaliada
-- em sql/consultas/gold/06_avaliacao_regressao_linear_gold.sql. Split
-- aleatorio invalidaria a avaliacao em serie temporal.
--
-- L1_REG=1.0 e L2_REG=1.0: mesmos valores da Silver e do modelo semanal
-- desta mesma Gold, para manter comparabilidade entre camadas e entre
-- granularidades. Nao houve varredura de hiperparametros.
-- CALCULATE_P_VALUES=FALSE, ENABLE_GLOBAL_EXPLAIN=TRUE: mesma justificativa
-- do modelo semanal (sql/modelo/gold/01_modelo_regressao_linear_semanal.sql).
--
-- Alvo e media de preco do mes seguinte (media de periodo), nao preco de um
-- dia -- ressalva de escala obrigatoria, gravada em
-- pdm-ceasa.metricas.comparacao_modelos junto com esta linha.
--
-- Regra do repositorio: script de treino nao se reexecuta por rotina.
-- CREATE OR REPLACE MODEL retreina ao rodar; para validar sintaxe sem
-- treinar, usar "bq query --dry_run --use_legacy_sql=false < este_arquivo".
-- LINEAR_REG tem inicializacao estocastica -- reexecutar sem mudar o
-- desenho do modelo nao reproduz a metrica exata.

CREATE OR REPLACE MODEL `pdm-ceasa.gold.modelo_regressao_linear_mensal`
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
  lag_1m,
  lag_12m,
  lag_24m,
  alvo
FROM `pdm-ceasa.gold.treino_mensal`
WHERE DATE(ano, mes, 1) <= '2025-12-31';
