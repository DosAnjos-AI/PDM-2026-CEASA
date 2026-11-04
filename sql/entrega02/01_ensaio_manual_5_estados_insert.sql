-- ==============================================================================
-- ENSAIO SINTETICO MANUAL -- 5 CEASAs SIMULTANEOS -- INSERT
-- Faz: em cada bronze.ceasa_<uf>, copia as linhas da data mais recente DAQUELE
--      CEASA para o dia seguinte, marcadas com arquivo = 'sintetico_manual_5'.
--      Os 5 INSERTs vao num bloco so, em sequencia imediata, para reproduzir
--      a rajada do ciclo-ceasa e testar o disparo por evento com 5 estados.
-- ATENCAO: e dado falso na bronze. O par TEM de ser rodado: depois de
--      conferir, rode 05_ensaio_manual_5_estados_delete.sql. Nao deixe o
--      sintetico na bronze durante o ciclo-ceasa (14:00) nem o plano B (16:30).
-- Cada tabela usa a propria data maxima (nao sao iguais entre os CEASAs).
-- Esquema: GO tem colunas diferentes das outras 4; nao importa aqui, porque
--      cada INSERT copia linhas da propria tabela com SELECT * REPLACE e so
--      toca data, ano, mes, dia e arquivo, que existem nas 5.
-- So acrescenta linhas: nenhuma linha existente e alterada; nenhum schema muda.
-- Idempotente por tabela: se a marca ja existir naquela tabela, nada e
--      inserido nela, e o proprio sintetico nunca e copiado para o dia seguinte.
-- Execucao: colar o bloco inteiro no console do BigQuery, ou pela CLI:
--   bq query --project_id=pdm-ceasa --use_legacy_sql=false < sql/entrega02/01_ensaio_manual_5_estados_insert.sql
-- ==============================================================================

INSERT INTO `pdm-ceasa.bronze.ceasa_go`
SELECT * REPLACE (
    DATE_ADD(data, INTERVAL 1 DAY) AS data,
    EXTRACT(YEAR FROM DATE_ADD(data, INTERVAL 1 DAY)) AS ano,
    EXTRACT(MONTH FROM DATE_ADD(data, INTERVAL 1 DAY)) AS mes,
    EXTRACT(DAY FROM DATE_ADD(data, INTERVAL 1 DAY)) AS dia,
    'sintetico_manual_5' AS arquivo
)
FROM `pdm-ceasa.bronze.ceasa_go`
WHERE data = (SELECT MAX(data) FROM `pdm-ceasa.bronze.ceasa_go` WHERE arquivo != 'sintetico_manual_5')
  AND arquivo != 'sintetico_manual_5'
  AND NOT EXISTS (SELECT 1 FROM `pdm-ceasa.bronze.ceasa_go` WHERE arquivo = 'sintetico_manual_5');

INSERT INTO `pdm-ceasa.bronze.ceasa_sc`
SELECT * REPLACE (
    DATE_ADD(data, INTERVAL 1 DAY) AS data,
    EXTRACT(YEAR FROM DATE_ADD(data, INTERVAL 1 DAY)) AS ano,
    EXTRACT(MONTH FROM DATE_ADD(data, INTERVAL 1 DAY)) AS mes,
    EXTRACT(DAY FROM DATE_ADD(data, INTERVAL 1 DAY)) AS dia,
    'sintetico_manual_5' AS arquivo
)
FROM `pdm-ceasa.bronze.ceasa_sc`
WHERE data = (SELECT MAX(data) FROM `pdm-ceasa.bronze.ceasa_sc` WHERE arquivo != 'sintetico_manual_5')
  AND arquivo != 'sintetico_manual_5'
  AND NOT EXISTS (SELECT 1 FROM `pdm-ceasa.bronze.ceasa_sc` WHERE arquivo = 'sintetico_manual_5');

INSERT INTO `pdm-ceasa.bronze.ceasa_ms`
SELECT * REPLACE (
    DATE_ADD(data, INTERVAL 1 DAY) AS data,
    EXTRACT(YEAR FROM DATE_ADD(data, INTERVAL 1 DAY)) AS ano,
    EXTRACT(MONTH FROM DATE_ADD(data, INTERVAL 1 DAY)) AS mes,
    EXTRACT(DAY FROM DATE_ADD(data, INTERVAL 1 DAY)) AS dia,
    'sintetico_manual_5' AS arquivo
)
FROM `pdm-ceasa.bronze.ceasa_ms`
WHERE data = (SELECT MAX(data) FROM `pdm-ceasa.bronze.ceasa_ms` WHERE arquivo != 'sintetico_manual_5')
  AND arquivo != 'sintetico_manual_5'
  AND NOT EXISTS (SELECT 1 FROM `pdm-ceasa.bronze.ceasa_ms` WHERE arquivo = 'sintetico_manual_5');

INSERT INTO `pdm-ceasa.bronze.ceasa_mg`
SELECT * REPLACE (
    DATE_ADD(data, INTERVAL 1 DAY) AS data,
    EXTRACT(YEAR FROM DATE_ADD(data, INTERVAL 1 DAY)) AS ano,
    EXTRACT(MONTH FROM DATE_ADD(data, INTERVAL 1 DAY)) AS mes,
    EXTRACT(DAY FROM DATE_ADD(data, INTERVAL 1 DAY)) AS dia,
    'sintetico_manual_5' AS arquivo
)
FROM `pdm-ceasa.bronze.ceasa_mg`
WHERE data = (SELECT MAX(data) FROM `pdm-ceasa.bronze.ceasa_mg` WHERE arquivo != 'sintetico_manual_5')
  AND arquivo != 'sintetico_manual_5'
  AND NOT EXISTS (SELECT 1 FROM `pdm-ceasa.bronze.ceasa_mg` WHERE arquivo = 'sintetico_manual_5');

INSERT INTO `pdm-ceasa.bronze.ceasa_es`
SELECT * REPLACE (
    DATE_ADD(data, INTERVAL 1 DAY) AS data,
    EXTRACT(YEAR FROM DATE_ADD(data, INTERVAL 1 DAY)) AS ano,
    EXTRACT(MONTH FROM DATE_ADD(data, INTERVAL 1 DAY)) AS mes,
    EXTRACT(DAY FROM DATE_ADD(data, INTERVAL 1 DAY)) AS dia,
    'sintetico_manual_5' AS arquivo
)
FROM `pdm-ceasa.bronze.ceasa_es`
WHERE data = (SELECT MAX(data) FROM `pdm-ceasa.bronze.ceasa_es` WHERE arquivo != 'sintetico_manual_5')
  AND arquivo != 'sintetico_manual_5'
  AND NOT EXISTS (SELECT 1 FROM `pdm-ceasa.bronze.ceasa_es` WHERE arquivo = 'sintetico_manual_5');
