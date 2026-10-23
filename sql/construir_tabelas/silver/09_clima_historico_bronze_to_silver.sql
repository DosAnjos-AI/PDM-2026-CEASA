-- ==============================================================================
-- CLIMA — Camada Bronze -> Prata (script de documentação/recriação)
-- Execução (CLI, a partir da raiz do repositório):
--   bq query --use_legacy_sql=false < sql/construir_tabelas/silver/09_clima_historico_bronze_to_silver.sql
-- Origem: pdm-ceasa.bronze.clima_historico (1 linha por data/estado, sem gaps de calendário)
-- Destino: pdm-ceasa.silver.clima_historico
-- ------------------------------------------------------------------------------
-- Lógica inferida e CONFIRMADA por amostra real (não deduzida):
--   - 1 linha de bronze por (data, estado); sem duplicidade; calendário contínuo
--     (nº de linhas = nº de dias corridos entre data_min e data_max, nos 5 estados).
--   - Cada métrica de prata é uma MÉDIA MÓVEL retroativa (trailing), por estado,
--     ordenada por data, incluindo o dia atual: ROWS BETWEEN (N-1) PRECEDING AND CURRENT ROW.
--   - Janela expansiva no início da série (ex.: dia 1 = só ele mesmo; dia 2 = média
--     dos 2 primeiros dias) — NÃO há NULL nos primeiros dias, e NÃO há preenchimento
--     de calendário (como no pipeline de cotações) porque o bronze já é contínuo.
--   - Aplica-se a MESMA média móvel às 5 métricas brutas (temp_media, umidade_media,
--     nebulosidade_media, precipitacao_mm, vento_max_kmh) — inclusive para
--     precipitacao_mm e vento_max_kmh, que também viram MÉDIA (não soma/máximo).
--   - Sem arredondamento (valores em FLOAT64 cheio, confirmado na amostra).
--   - Colunas do bronze não carregadas para a prata: cidade, fonte, data_coleta.
-- ==============================================================================

CREATE OR REPLACE TABLE `pdm-ceasa.silver.clima_historico` AS
SELECT
    data,
    estado,

    -- Janela de 3 dias
    AVG(temp_media)          OVER (w3)  AS temp_media_3d,
    AVG(umidade_media)       OVER (w3)  AS umidade_media_3d,
    AVG(nebulosidade_media)  OVER (w3)  AS nebulosidade_media_3d,
    AVG(precipitacao_mm)     OVER (w3)  AS precipitacao_mm_3d,
    AVG(vento_max_kmh)       OVER (w3)  AS vento_max_kmh_3d,

    -- Janela de 7 dias
    AVG(temp_media)          OVER (w7)  AS temp_media_7d,
    AVG(umidade_media)       OVER (w7)  AS umidade_media_7d,
    AVG(nebulosidade_media)  OVER (w7)  AS nebulosidade_media_7d,
    AVG(precipitacao_mm)     OVER (w7)  AS precipitacao_mm_7d,
    AVG(vento_max_kmh)       OVER (w7)  AS vento_max_kmh_7d,

    -- Janela de 14 dias
    AVG(temp_media)          OVER (w14) AS temp_media_14d,
    AVG(umidade_media)       OVER (w14) AS umidade_media_14d,
    AVG(nebulosidade_media)  OVER (w14) AS nebulosidade_media_14d,
    AVG(precipitacao_mm)     OVER (w14) AS precipitacao_mm_14d,
    AVG(vento_max_kmh)       OVER (w14) AS vento_max_kmh_14d,

    -- Janela de 30 dias
    AVG(temp_media)          OVER (w30) AS temp_media_30d,
    AVG(umidade_media)       OVER (w30) AS umidade_media_30d,
    AVG(nebulosidade_media)  OVER (w30) AS nebulosidade_media_30d,
    AVG(precipitacao_mm)     OVER (w30) AS precipitacao_mm_30d,
    AVG(vento_max_kmh)       OVER (w30) AS vento_max_kmh_30d,

    -- Janela de 60 dias
    AVG(temp_media)          OVER (w60) AS temp_media_60d,
    AVG(umidade_media)       OVER (w60) AS umidade_media_60d,
    AVG(nebulosidade_media)  OVER (w60) AS nebulosidade_media_60d,
    AVG(precipitacao_mm)     OVER (w60) AS precipitacao_mm_60d,
    AVG(vento_max_kmh)       OVER (w60) AS vento_max_kmh_60d

FROM `pdm-ceasa.bronze.clima_historico`
WINDOW
    w3  AS (PARTITION BY estado ORDER BY data ROWS BETWEEN 2  PRECEDING AND CURRENT ROW),
    w7  AS (PARTITION BY estado ORDER BY data ROWS BETWEEN 6  PRECEDING AND CURRENT ROW),
    w14 AS (PARTITION BY estado ORDER BY data ROWS BETWEEN 13 PRECEDING AND CURRENT ROW),
    w30 AS (PARTITION BY estado ORDER BY data ROWS BETWEEN 29 PRECEDING AND CURRENT ROW),
    w60 AS (PARTITION BY estado ORDER BY data ROWS BETWEEN 59 PRECEDING AND CURRENT ROW)
ORDER BY estado, data;
