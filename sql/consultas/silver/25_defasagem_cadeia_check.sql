-- ==============================================================================
-- Defasagem da cadeia bronze -> prata -> unificado -> ouro (somente leitura)
-- Execucao (CLI, a partir da raiz do repositorio):
--   bq query --project_id=pdm-ceasa --use_legacy_sql=false < sql/consultas/silver/25_defasagem_cadeia_check.sql
-- Devolve uma linha por tabela atrasada, com o par de horarios que justifica,
-- e SEMPRE uma linha regra='resumo' com a contagem por regra. "Em dia" e o
-- resumo com zeros, nunca a ausencia de linhas: quem le esta consulta (script
-- e Workflow) tem de distinguir "em dia" de "a consulta nao respondeu".
-- Regras:
--   1. bronze.ceasa_<uf> mais nova que silver.ceasa_<uf>  -> estado atrasado
--   2. prata mais nova das 5 mais nova que silver.ceasa_unificado -> unificado atrasado
--   3. silver.ceasa_unificado mais novo que uma gold -> aquela gold atrasada
-- Fonte do horario: __TABLES__ de cada dataset. INFORMATION_SCHEMA.TABLES nao
-- tem horario de modificacao, e TABLE_STORAGE so existe no nivel da regiao,
-- onde a leitura e negada neste projeto. __TABLES__.last_modified_time bate
-- com o lastModifiedTime da API (conferido em 2026-11-04).
-- Tabela esperada ausente aborta com erro: um LEFT JOIN em silencio devolveria
-- NULL, e NULL nunca e "mais novo", ou seja, a consulta diria "em dia" sobre
-- uma cadeia quebrada.
-- Clima fica de fora de proposito: silver.clima_historico e reconstruida pelo
-- plano B das 16:30, nao pela cadeia por estado.
-- ==============================================================================

-- --- Variaveis ---
-- Lista fechada da cadeia: (camada, tabela, uf). uf liga bronze e prata do
-- mesmo estado; NULL para unificado e ouro.
DECLARE esperadas ARRAY<STRUCT<camada STRING, tabela STRING, uf STRING>> DEFAULT [
    STRUCT('bronze' AS camada, 'ceasa_go' AS tabela, 'go' AS uf),
    ('bronze', 'ceasa_sc', 'sc'),
    ('bronze', 'ceasa_ms', 'ms'),
    ('bronze', 'ceasa_mg', 'mg'),
    ('bronze', 'ceasa_es', 'es'),
    ('silver', 'ceasa_go', 'go'),
    ('silver', 'ceasa_sc', 'sc'),
    ('silver', 'ceasa_ms', 'ms'),
    ('silver', 'ceasa_mg', 'mg'),
    ('silver', 'ceasa_es', 'es'),
    ('silver', 'ceasa_unificado', NULL),
    ('gold', 'ceasa_unificado_semanal', NULL),
    ('gold', 'ceasa_unificado_quinzenal', NULL)
];

DECLARE cadeia ARRAY<STRUCT<camada STRING, tabela STRING, uf STRING, modificada_em TIMESTAMP>>;
DECLARE ausentes STRING;

SET cadeia = (
    SELECT ARRAY_AGG(STRUCT(e.camada, e.tabela, e.uf, m.modificada_em))
    FROM UNNEST(esperadas) AS e
    LEFT JOIN (
        SELECT dataset_id AS camada, table_id AS tabela, TIMESTAMP_MILLIS(last_modified_time) AS modificada_em
        FROM `pdm-ceasa.bronze.__TABLES__`
        UNION ALL
        SELECT dataset_id, table_id, TIMESTAMP_MILLIS(last_modified_time)
        FROM `pdm-ceasa.silver.__TABLES__`
        UNION ALL
        SELECT dataset_id, table_id, TIMESTAMP_MILLIS(last_modified_time)
        FROM `pdm-ceasa.gold.__TABLES__`
    ) AS m
      ON m.camada = e.camada AND m.tabela = e.tabela
);

SET ausentes = (
    SELECT STRING_AGG(CONCAT(camada, '.', tabela), ', ' ORDER BY camada, tabela)
    FROM UNNEST(cadeia)
    WHERE modificada_em IS NULL
);

IF ausentes IS NOT NULL THEN
    RAISE USING MESSAGE = CONCAT('defasagem: tabela esperada ausente na cadeia: ', ausentes);
END IF;

WITH
pratas AS (
    SELECT tabela, modificada_em FROM UNNEST(cadeia) WHERE camada = 'silver' AND uf IS NOT NULL
),
prata_mais_nova AS (
    SELECT tabela, modificada_em FROM pratas ORDER BY modificada_em DESC LIMIT 1
),
unificado AS (
    SELECT tabela, modificada_em FROM UNNEST(cadeia) WHERE camada = 'silver' AND tabela = 'ceasa_unificado'
),
atrasos AS (
    -- regra 1: estado
    SELECT
        'estado' AS regra,
        CONCAT('silver.', p.tabela) AS tabela_atrasada,
        p.modificada_em AS atrasada_modificada_em,
        CONCAT('bronze.', b.tabela) AS referencia,
        b.modificada_em AS referencia_modificada_em
    FROM UNNEST(cadeia) AS b
    JOIN UNNEST(cadeia) AS p
      ON p.uf = b.uf AND p.camada = 'silver'
    WHERE b.camada = 'bronze' AND b.modificada_em > p.modificada_em

    UNION ALL

    -- regra 2: unificado
    SELECT 'unificado', 'silver.ceasa_unificado', u.modificada_em, CONCAT('silver.', n.tabela), n.modificada_em
    FROM unificado AS u CROSS JOIN prata_mais_nova AS n
    WHERE n.modificada_em > u.modificada_em

    UNION ALL

    -- regra 3: ouro
    SELECT 'gold', CONCAT('gold.', g.tabela), g.modificada_em, 'silver.ceasa_unificado', u.modificada_em
    FROM UNNEST(cadeia) AS g CROSS JOIN unificado AS u
    WHERE g.camada = 'gold' AND u.modificada_em > g.modificada_em
)
SELECT
    regra, tabela_atrasada, atrasada_modificada_brt, referencia, referencia_modificada_brt,
    atrasos_estado, atrasos_unificado, atrasos_gold
FROM (
    -- resumo primeiro: agregacao sobre conjunto vazio ainda devolve 1 linha,
    -- com zeros, e e isso que garante a linha mesmo com a cadeia em dia
    SELECT
        0 AS ordem,
        'resumo' AS regra,
        CAST(NULL AS STRING) AS tabela_atrasada,
        CAST(NULL AS STRING) AS atrasada_modificada_brt,
        CAST(NULL AS STRING) AS referencia,
        CAST(NULL AS STRING) AS referencia_modificada_brt,
        COUNTIF(regra = 'estado') AS atrasos_estado,
        COUNTIF(regra = 'unificado') AS atrasos_unificado,
        COUNTIF(regra = 'gold') AS atrasos_gold
    FROM atrasos

    UNION ALL

    SELECT
        1,
        regra,
        tabela_atrasada,
        FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', atrasada_modificada_em, 'America/Sao_Paulo'),
        referencia,
        FORMAT_TIMESTAMP('%Y-%m-%d %H:%M:%S', referencia_modificada_em, 'America/Sao_Paulo'),
        CAST(NULL AS INT64),
        CAST(NULL AS INT64),
        CAST(NULL AS INT64)
    FROM atrasos
)
ORDER BY ordem, regra, tabela_atrasada;
