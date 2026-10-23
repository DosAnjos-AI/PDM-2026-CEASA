-- ==============================================================================
-- CEASA UNIFICADO — Camada OURO (agregações semanal e quinzenal)
-- Execução (CLI, a partir da raiz do repositório):
--   bq query --use_legacy_sql=false < sql/construir_tabelas/gold/06_ceasa_unificado_semanal_quinzenal.sql
-- Origem: pdm-ceasa.silver.ceasa_unificado
-- Destino: pdm-ceasa.gold.ceasa_unificado_semanal
--          pdm-ceasa.gold.ceasa_unificado_quinzenal
-- ------------------------------------------------------------------------------
-- Decisões de período (escolhidas por mim, sem instrução explícita do usuário;
-- justificativa abaixo):
--
--   SEMANA -> padrão ISO 8601 (EXTRACT(ISOYEAR/ISOWEEK) + DATE_TRUNC(..., ISOWEEK)).
--     Motivo: segunda a domingo, sem "semana quebrada" no início/fim do ano como
--     ocorre no padrão US (domingo-sábado, default do BigQuery); é o padrão
--     usado em séries temporais/mercado agropecuário no Brasil e evita viés de
--     calendário ao comparar a mesma semana entre anos diferentes.
--
--   QUINZENA -> por mês civil: dias 1-15 = quinzena 1, dias 16-fim do mês = quinzena 2.
--     Motivo: é a definição comercial padrão de "quinzena" no Brasil (ex.: contratos,
--     folha de pagamento, boletins de preço agro), e se alinha ao calendário
--     mensal (ano/mês) que já é usado nas colunas ano/mes/dia da camada prata.
--
-- Colunas agregadas: os 3 preços (preco_minimo, preco_comum, preco_maximo) sempre.
-- Clima: regra definida pelo usuário — descartar qualquer janela de clima MENOR
-- que o próprio período do agrupamento, porque média de uma janela mais curta
-- dentro de um agrupamento mais longo é redundante/sem sentido (média de média).
--   SEMANAL  (~7 dias)  -> mantém só 7d, 14d, 30d, 60d (descarta 3d).
--   QUINZENAL (~15 dias) -> mantém só 30d, 60d (descarta 3d, 7d e 14d, todas < 15 dias).
-- dias_observados = nº de dias-base que compuseram cada média (controle de qualidade).
-- ==============================================================================

CREATE SCHEMA IF NOT EXISTS `pdm-ceasa.gold`
OPTIONS (location = 'US');

-- ------------------------------------------------------------------------------
-- 1. SEMANAL (ISO 8601)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `pdm-ceasa.gold.ceasa_unificado_semanal` AS
SELECT
    ceasa,
    grupo_canonico,
    produto_canonico,
    EXTRACT(ISOYEAR FROM data) AS ano_iso,
    EXTRACT(ISOWEEK FROM data) AS semana_iso,
    DATE_TRUNC(data, ISOWEEK) AS semana_inicio,

    COUNT(*) AS dias_observados,

    AVG(preco_minimo) AS preco_minimo,
    AVG(preco_comum)  AS preco_comum,
    AVG(preco_maximo) AS preco_maximo,

    -- clima: descartada a janela 3d (< 7 dias da semana) — ver justificativa acima
    AVG(temp_media_7d)         AS temp_media_7d,
    AVG(umidade_media_7d)      AS umidade_media_7d,
    AVG(nebulosidade_media_7d) AS nebulosidade_media_7d,
    AVG(precipitacao_mm_7d)    AS precipitacao_mm_7d,
    AVG(vento_max_kmh_7d)      AS vento_max_kmh_7d,

    AVG(temp_media_14d)         AS temp_media_14d,
    AVG(umidade_media_14d)      AS umidade_media_14d,
    AVG(nebulosidade_media_14d) AS nebulosidade_media_14d,
    AVG(precipitacao_mm_14d)    AS precipitacao_mm_14d,
    AVG(vento_max_kmh_14d)      AS vento_max_kmh_14d,

    AVG(temp_media_30d)         AS temp_media_30d,
    AVG(umidade_media_30d)      AS umidade_media_30d,
    AVG(nebulosidade_media_30d) AS nebulosidade_media_30d,
    AVG(precipitacao_mm_30d)    AS precipitacao_mm_30d,
    AVG(vento_max_kmh_30d)      AS vento_max_kmh_30d,

    AVG(temp_media_60d)         AS temp_media_60d,
    AVG(umidade_media_60d)      AS umidade_media_60d,
    AVG(nebulosidade_media_60d) AS nebulosidade_media_60d,
    AVG(precipitacao_mm_60d)    AS precipitacao_mm_60d,
    AVG(vento_max_kmh_60d)      AS vento_max_kmh_60d

FROM `pdm-ceasa.silver.ceasa_unificado`
GROUP BY ceasa, grupo_canonico, produto_canonico, ano_iso, semana_iso, semana_inicio
ORDER BY ceasa, produto_canonico, ano_iso, semana_iso;

-- ------------------------------------------------------------------------------
-- 2. QUINZENAL (mês civil: dias 1-15 / 16-fim do mês)
-- ------------------------------------------------------------------------------
CREATE OR REPLACE TABLE `pdm-ceasa.gold.ceasa_unificado_quinzenal` AS
SELECT
    ceasa,
    grupo_canonico,
    produto_canonico,
    EXTRACT(YEAR FROM data) AS ano,
    EXTRACT(MONTH FROM data) AS mes,
    IF(EXTRACT(DAY FROM data) <= 15, 1, 2) AS quinzena,

    COUNT(*) AS dias_observados,

    AVG(preco_minimo) AS preco_minimo,
    AVG(preco_comum)  AS preco_comum,
    AVG(preco_maximo) AS preco_maximo,

    -- clima: descartadas as janelas 3d, 7d e 14d (todas < 15 dias da quinzena)
    AVG(temp_media_30d)         AS temp_media_30d,
    AVG(umidade_media_30d)      AS umidade_media_30d,
    AVG(nebulosidade_media_30d) AS nebulosidade_media_30d,
    AVG(precipitacao_mm_30d)    AS precipitacao_mm_30d,
    AVG(vento_max_kmh_30d)      AS vento_max_kmh_30d,

    AVG(temp_media_60d)         AS temp_media_60d,
    AVG(umidade_media_60d)      AS umidade_media_60d,
    AVG(nebulosidade_media_60d) AS nebulosidade_media_60d,
    AVG(precipitacao_mm_60d)    AS precipitacao_mm_60d,
    AVG(vento_max_kmh_60d)      AS vento_max_kmh_60d

FROM `pdm-ceasa.silver.ceasa_unificado`
GROUP BY ceasa, grupo_canonico, produto_canonico, ano, mes, quinzena
ORDER BY ceasa, produto_canonico, ano, mes, quinzena;
