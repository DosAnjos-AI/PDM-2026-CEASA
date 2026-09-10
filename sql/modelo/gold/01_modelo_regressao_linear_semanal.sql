-- Treino do modelo de regressao linear com regularizacao elastic net sobre
-- gold.treino_semanal (base semanal da Gold).
-- Entrada: produto, classe, grupo, isoyear, isoweek, lag_1s, lag_2s,
-- lag_4s, lag_52s, lag_104s -> alvo. data_inicio_semana NAO entra no SELECT
-- de features -- so aparece no WHERE, para o corte temporal do split (mesmo
-- padrao de sql/modelo/silver/01_modelo_regressao_linear.sql).
-- Split temporal: treino usa data_inicio_semana <= 2025-12-31 (54.958
-- linhas, conferido antes deste treino); a particao de teste
-- (data_inicio_semana > 2025-12-31, 5.426 linhas) fica de fora e e avaliada
-- em sql/consultas/gold/06_avaliacao_regressao_linear_gold.sql. Split
-- aleatorio invalidaria a avaliacao em serie temporal.
--
-- L1_REG=1.0 e L2_REG=1.0: mesmos valores da Silver
-- (sql/modelo/silver/01_modelo_regressao_linear.sql), para manter
-- comparabilidade entre camadas. Nao houve varredura de hiperparametros
-- para a Gold -- decisao declarada no relatorio, nao ajuste escondido.
-- CALCULATE_P_VALUES=FALSE: nao precisamos de significancia estatistica por
-- coeficiente para este entregavel.
-- ENABLE_GLOBAL_EXPLAIN=TRUE: peso das features e material de relatorio e
-- de slide, e permite comparar contra a arvore treinada sobre o mesmo vetor
-- (sql/modelo/gold/03_modelo_regressao_arvore_semanal.sql).
--
-- Alvo e media de preco da semana seguinte (media de periodo), nao preco de
-- um dia -- ressalva de escala obrigatoria, gravada em
-- pdm-ceasa.metricas.comparacao_modelos junto com esta linha.
--
-- Regra do repositorio: script de treino nao se reexecuta por rotina.
-- CREATE OR REPLACE MODEL retreina ao rodar; para validar sintaxe sem
-- treinar, usar "bq query --dry_run --use_legacy_sql=false < este_arquivo".
-- LINEAR_REG tem inicializacao estocastica -- reexecutar sem mudar o
-- desenho do modelo nao reproduz a metrica exata; variacao sem mudanca de
-- desenho e ruido do treino, nao regressao do modelo.

CREATE OR REPLACE MODEL `pdm-ceasa.gold.modelo_regressao_linear_semanal`
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
