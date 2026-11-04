-- ==============================================================================
-- ENSAIO SINTETICO MANUAL -- SO CEASA-GO -- INSERT
-- Faz: copia as linhas da data mais recente de bronze.ceasa_go para o dia
--      seguinte, marcadas com arquivo = 'sintetico_manual_go'. Serve so para
--      testar o disparo por evento com um estado.
-- ATENCAO: e dado falso na bronze. O par TEM de ser rodado: depois de
--      conferir, rode 07_ensaio_manual_go_delete.sql. Nao deixe o sintetico
--      na bronze durante o ciclo-ceasa (14:00) nem o plano B (16:30).
-- So acrescenta linhas: nenhuma linha existente e alterada; nenhum schema muda.
-- Idempotente: se a marca ja existir, nao insere nada (e nunca copia o proprio
--      sintetico para o dia seguinte).
-- Execucao: colar no console do BigQuery, ou pela CLI a partir da raiz:
--   bq query --project_id=pdm-ceasa --use_legacy_sql=false < sql/entrega02/06_ensaio_manual_go_insert.sql
-- ==============================================================================

INSERT INTO `pdm-ceasa.bronze.ceasa_go`
SELECT * REPLACE (
    DATE_ADD(data, INTERVAL 1 DAY) AS data,
    EXTRACT(YEAR FROM DATE_ADD(data, INTERVAL 1 DAY)) AS ano,
    EXTRACT(MONTH FROM DATE_ADD(data, INTERVAL 1 DAY)) AS mes,
    EXTRACT(DAY FROM DATE_ADD(data, INTERVAL 1 DAY)) AS dia,
    'sintetico_manual_go' AS arquivo
)
FROM `pdm-ceasa.bronze.ceasa_go`
WHERE data = (
        SELECT MAX(data) FROM `pdm-ceasa.bronze.ceasa_go`
        WHERE arquivo != 'sintetico_manual_go'
    )
  AND arquivo != 'sintetico_manual_go'
  AND NOT EXISTS (
        SELECT 1 FROM `pdm-ceasa.bronze.ceasa_go` WHERE arquivo = 'sintetico_manual_go'
    );
