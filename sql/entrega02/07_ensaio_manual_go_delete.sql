-- ==============================================================================
-- ENSAIO SINTETICO MANUAL -- SO CEASA-GO -- DELETE
-- Faz: remove de bronze.ceasa_go exatamente as linhas com
--      arquivo = 'sintetico_manual_go', gravadas por
--      06_ensaio_manual_go_insert.sql. Nenhuma linha real usa essa marca
--      (conferido antes do ensaio).
-- ATENCAO: e a segunda metade obrigatoria do par de ensaio. Rode depois de
--      conferir a prata, e antes do ciclo-ceasa (14:00) e do plano B (16:30).
-- Idempotente: sem linha sintetica, nao remove nada.
-- Execucao: colar no console do BigQuery, ou pela CLI a partir da raiz:
--   bq query --project_id=pdm-ceasa --use_legacy_sql=false < sql/entrega02/07_ensaio_manual_go_delete.sql
-- ==============================================================================

DELETE FROM `pdm-ceasa.bronze.ceasa_go`
WHERE arquivo = 'sintetico_manual_go';
