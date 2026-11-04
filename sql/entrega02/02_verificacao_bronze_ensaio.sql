-- ==============================================================================
-- Conferencia da bronze -- ensaio sintetico manual dos 5 CEASAs (somente leitura)
-- Execucao: colar no console do BigQuery, ou pela CLI:
--   bq query --project_id=pdm-ceasa --use_legacy_sql=false < sql/entrega02/02_verificacao_bronze_ensaio.sql
-- Uma linha por CEASA: data maxima, linhas sinteticas e total.
-- Esperado ANTES do INSERT (medido em 2026-11-04 18:26):
--   go 2026-11-03 / 0 / 420710   sc 2026-11-04 / 0 / 458956
--   ms 2026-10-02 / 0 / 337855   mg 2026-11-04 / 0 / 478727
--   es 2026-11-04 / 0 / 247569
-- Esperado DEPOIS do INSERT: data maxima +1 dia; sinteticas = go 230,
--   sc 250, ms 167, mg 244, es 152; total = antes + sinteticas.
-- Esperado DEPOIS do DELETE: igual ao ANTES.
-- ==============================================================================

SELECT 'go' AS uf, MAX(data) AS data_max, COUNTIF(arquivo = 'sintetico_manual_5') AS sinteticas, COUNT(*) AS total FROM `pdm-ceasa.bronze.ceasa_go`
UNION ALL SELECT 'sc', MAX(data), COUNTIF(arquivo = 'sintetico_manual_5'), COUNT(*) FROM `pdm-ceasa.bronze.ceasa_sc`
UNION ALL SELECT 'ms', MAX(data), COUNTIF(arquivo = 'sintetico_manual_5'), COUNT(*) FROM `pdm-ceasa.bronze.ceasa_ms`
UNION ALL SELECT 'mg', MAX(data), COUNTIF(arquivo = 'sintetico_manual_5'), COUNT(*) FROM `pdm-ceasa.bronze.ceasa_mg`
UNION ALL SELECT 'es', MAX(data), COUNTIF(arquivo = 'sintetico_manual_5'), COUNT(*) FROM `pdm-ceasa.bronze.ceasa_es`
ORDER BY uf;
