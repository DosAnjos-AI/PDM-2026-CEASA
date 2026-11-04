-- ==============================================================================
-- ENSAIO SINTETICO MANUAL -- 5 CEASAs SIMULTANEOS -- DELETE
-- Faz: remove das 5 bronze.ceasa_<uf> exatamente as linhas com
--      arquivo = 'sintetico_manual_5', gravadas por
--      01_ensaio_manual_5_estados_insert.sql. Nenhuma linha real usa essa
--      marca e nenhuma tem arquivo nulo (conferido antes do ensaio).
--      Num bloco so, como o INSERT, para reproduzir a rajada na volta.
-- ATENCAO: e a segunda metade obrigatoria do par de ensaio. Rode depois de
--      conferir a prata, e antes do ciclo-ceasa (14:00) e do plano B (16:30).
-- Idempotente: sem linha sintetica, nao remove nada.
-- Execucao: colar o bloco inteiro no console do BigQuery, ou pela CLI:
--   bq query --project_id=pdm-ceasa --use_legacy_sql=false < sql/entrega02/05_ensaio_manual_5_estados_delete.sql
-- ==============================================================================

DELETE FROM `pdm-ceasa.bronze.ceasa_go` WHERE arquivo = 'sintetico_manual_5';
DELETE FROM `pdm-ceasa.bronze.ceasa_sc` WHERE arquivo = 'sintetico_manual_5';
DELETE FROM `pdm-ceasa.bronze.ceasa_ms` WHERE arquivo = 'sintetico_manual_5';
DELETE FROM `pdm-ceasa.bronze.ceasa_mg` WHERE arquivo = 'sintetico_manual_5';
DELETE FROM `pdm-ceasa.bronze.ceasa_es` WHERE arquivo = 'sintetico_manual_5';
