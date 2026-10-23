-- ==============================================================================
-- CEASA UNIFICADO — consolidação (UNION ALL) das 5 tabelas prata
-- Execução (CLI, a partir da raiz do repositório):
--   bq query --use_legacy_sql=false < sql/construir_tabelas/silver/15_ceasa_unificado.sql
-- Origem: silver.ceasa_go, ceasa_sc, ceasa_ms, ceasa_mg, ceasa_es (35 colunas cada:
--         10 de cotação + 25 de clima)
-- Destino: pdm-ceasa.silver.ceasa_unificado
-- Observação: colunas selecionadas de forma explícita e nomeada (não SELECT *)
--             para garantir alinhamento correto em caso de qualquer diferença de
--             ordem física entre as 5 tabelas de origem.
-- ==============================================================================

CREATE OR REPLACE TABLE `pdm-ceasa.silver.ceasa_unificado` AS
SELECT
    data, ano, mes, dia, ceasa, grupo_canonico, produto_canonico,
    preco_minimo, preco_comum, preco_maximo,
    temp_media_3d, umidade_media_3d, nebulosidade_media_3d, precipitacao_mm_3d, vento_max_kmh_3d,
    temp_media_7d, umidade_media_7d, nebulosidade_media_7d, precipitacao_mm_7d, vento_max_kmh_7d,
    temp_media_14d, umidade_media_14d, nebulosidade_media_14d, precipitacao_mm_14d, vento_max_kmh_14d,
    temp_media_30d, umidade_media_30d, nebulosidade_media_30d, precipitacao_mm_30d, vento_max_kmh_30d,
    temp_media_60d, umidade_media_60d, nebulosidade_media_60d, precipitacao_mm_60d, vento_max_kmh_60d
FROM `pdm-ceasa.silver.ceasa_go`

UNION ALL

SELECT
    data, ano, mes, dia, ceasa, grupo_canonico, produto_canonico,
    preco_minimo, preco_comum, preco_maximo,
    temp_media_3d, umidade_media_3d, nebulosidade_media_3d, precipitacao_mm_3d, vento_max_kmh_3d,
    temp_media_7d, umidade_media_7d, nebulosidade_media_7d, precipitacao_mm_7d, vento_max_kmh_7d,
    temp_media_14d, umidade_media_14d, nebulosidade_media_14d, precipitacao_mm_14d, vento_max_kmh_14d,
    temp_media_30d, umidade_media_30d, nebulosidade_media_30d, precipitacao_mm_30d, vento_max_kmh_30d,
    temp_media_60d, umidade_media_60d, nebulosidade_media_60d, precipitacao_mm_60d, vento_max_kmh_60d
FROM `pdm-ceasa.silver.ceasa_sc`

UNION ALL

SELECT
    data, ano, mes, dia, ceasa, grupo_canonico, produto_canonico,
    preco_minimo, preco_comum, preco_maximo,
    temp_media_3d, umidade_media_3d, nebulosidade_media_3d, precipitacao_mm_3d, vento_max_kmh_3d,
    temp_media_7d, umidade_media_7d, nebulosidade_media_7d, precipitacao_mm_7d, vento_max_kmh_7d,
    temp_media_14d, umidade_media_14d, nebulosidade_media_14d, precipitacao_mm_14d, vento_max_kmh_14d,
    temp_media_30d, umidade_media_30d, nebulosidade_media_30d, precipitacao_mm_30d, vento_max_kmh_30d,
    temp_media_60d, umidade_media_60d, nebulosidade_media_60d, precipitacao_mm_60d, vento_max_kmh_60d
FROM `pdm-ceasa.silver.ceasa_ms`

UNION ALL

SELECT
    data, ano, mes, dia, ceasa, grupo_canonico, produto_canonico,
    preco_minimo, preco_comum, preco_maximo,
    temp_media_3d, umidade_media_3d, nebulosidade_media_3d, precipitacao_mm_3d, vento_max_kmh_3d,
    temp_media_7d, umidade_media_7d, nebulosidade_media_7d, precipitacao_mm_7d, vento_max_kmh_7d,
    temp_media_14d, umidade_media_14d, nebulosidade_media_14d, precipitacao_mm_14d, vento_max_kmh_14d,
    temp_media_30d, umidade_media_30d, nebulosidade_media_30d, precipitacao_mm_30d, vento_max_kmh_30d,
    temp_media_60d, umidade_media_60d, nebulosidade_media_60d, precipitacao_mm_60d, vento_max_kmh_60d
FROM `pdm-ceasa.silver.ceasa_mg`

UNION ALL

SELECT
    data, ano, mes, dia, ceasa, grupo_canonico, produto_canonico,
    preco_minimo, preco_comum, preco_maximo,
    temp_media_3d, umidade_media_3d, nebulosidade_media_3d, precipitacao_mm_3d, vento_max_kmh_3d,
    temp_media_7d, umidade_media_7d, nebulosidade_media_7d, precipitacao_mm_7d, vento_max_kmh_7d,
    temp_media_14d, umidade_media_14d, nebulosidade_media_14d, precipitacao_mm_14d, vento_max_kmh_14d,
    temp_media_30d, umidade_media_30d, nebulosidade_media_30d, precipitacao_mm_30d, vento_max_kmh_30d,
    temp_media_60d, umidade_media_60d, nebulosidade_media_60d, precipitacao_mm_60d, vento_max_kmh_60d
FROM `pdm-ceasa.silver.ceasa_es`

ORDER BY ceasa, produto_canonico, data;
