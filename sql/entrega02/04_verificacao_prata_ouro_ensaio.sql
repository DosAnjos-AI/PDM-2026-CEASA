-- ==============================================================================
-- Conferencia da prata e do ouro -- ensaio sintetico manual dos 5 CEASAs
-- (somente leitura)
-- Execucao: colar no console do BigQuery, ou pela CLI:
--   bq query --project_id=pdm-ceasa --use_legacy_sql=false < sql/entrega02/04_verificacao_prata_ouro_ensaio.sql
-- Cobre as 5 pratas, o silver.ceasa_unificado (total e por estado: e a tabela
-- que os modelos leem) e as 2 gold. modificada_brt mostra se a tabela foi de
-- fato reconstruida depois do INSERT/DELETE -- nas gold a contagem pode nao
-- mudar (os dias sinteticos caem em semana/quinzena ja existentes).
-- Esperado ANTES do INSERT (medido em 2026-11-04):
--   prata go 2026-11-03/120566  sc 2026-11-04/62475  ms 2026-10-02/52525
--         mg 2026-11-04/45875   es 2026-11-04/45698
--   unificado 327139 (por estado = a prata de cada um)
--   gold semanal 46846, quinzenal 21621
-- Esperado DEPOIS do INSERT, com a cadeia pronta: data maxima de cada prata
--   e de cada estado no unificado +1 dia (go 11-04, sc/mg/es 11-05, ms 10-03);
--   contagens maiores (+1 dia por produto); unificado por estado = prata do
--   estado; gold com modificada_brt depois do INSERT.
-- Esperado DEPOIS do DELETE, com a cadeia pronta: tudo igual ao ANTES.
-- ==============================================================================

WITH ultima AS (
    SELECT dataset_id, table_id, TIMESTAMP_MILLIS(last_modified_time) AS modificada_em FROM `pdm-ceasa.silver.__TABLES__`
    UNION ALL
    SELECT dataset_id, table_id, TIMESTAMP_MILLIS(last_modified_time) FROM `pdm-ceasa.gold.__TABLES__`
),
contagens AS (
    SELECT 'silver' AS camada, 'ceasa_go' AS tabela, 'GO' AS estado, MAX(data) AS data_max, COUNT(*) AS linhas FROM `pdm-ceasa.silver.ceasa_go`
    UNION ALL SELECT 'silver', 'ceasa_sc', 'SC', MAX(data), COUNT(*) FROM `pdm-ceasa.silver.ceasa_sc`
    UNION ALL SELECT 'silver', 'ceasa_ms', 'MS', MAX(data), COUNT(*) FROM `pdm-ceasa.silver.ceasa_ms`
    UNION ALL SELECT 'silver', 'ceasa_mg', 'MG', MAX(data), COUNT(*) FROM `pdm-ceasa.silver.ceasa_mg`
    UNION ALL SELECT 'silver', 'ceasa_es', 'ES', MAX(data), COUNT(*) FROM `pdm-ceasa.silver.ceasa_es`
    UNION ALL SELECT 'silver', 'ceasa_unificado', 'TOTAL', MAX(data), COUNT(*) FROM `pdm-ceasa.silver.ceasa_unificado`
    UNION ALL SELECT 'silver', 'ceasa_unificado', ceasa, MAX(data), COUNT(*) FROM `pdm-ceasa.silver.ceasa_unificado` GROUP BY ceasa
    UNION ALL SELECT 'gold', 'ceasa_unificado_semanal', 'TOTAL', MAX(semana_inicio), COUNT(*) FROM `pdm-ceasa.gold.ceasa_unificado_semanal`
    UNION ALL SELECT 'gold', 'ceasa_unificado_quinzenal', 'TOTAL', MAX(DATE(ano, mes, 1)), COUNT(*) FROM `pdm-ceasa.gold.ceasa_unificado_quinzenal`
)
SELECT
    c.camada,
    c.tabela,
    c.estado,
    c.data_max,
    c.linhas,
    FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', u.modificada_em, 'America/Sao_Paulo') AS modificada_brt
FROM contagens AS c
LEFT JOIN ultima AS u
  ON u.dataset_id = c.camada AND u.table_id = c.tabela
ORDER BY c.camada DESC, c.tabela, c.estado;
