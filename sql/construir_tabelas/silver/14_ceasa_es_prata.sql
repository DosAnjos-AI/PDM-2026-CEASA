-- ==============================================================================
-- CEASA-ES — Camada Prata (100% autocontida)
-- Execução (CLI, a partir da raiz do repositório):
--   bq query --use_legacy_sql=false < sql/construir_tabelas/silver/14_ceasa_es_prata.sql
-- Origem: SOMENTE tabelas bronze (pdm-ceasa.bronze.ceasa_es + pdm-ceasa.silver.clima_historico)
-- Destino: pdm-ceasa.silver.ceasa_es
-- Observação: de-para embutido como CASE literal (idêntico ao script de produção
--             sql_script_ceasa_es_silver_pipeline.md), sem dependência de
--             silver.de_para_produtos. Mesma lógica validada em produção
--             (silver.ceasa_es), agora gravando direto em produção (silver).
-- Correção (validação de 2026-10-19): 'LARANJA LIMA' removido do mapeamento.
--             O script original previa esse produto, mas silver.ceasa_es (produção)
--             nunca o materializou (0 linhas). Para bater com a produção, a
--             este script passa a excluí-lo também.
-- ==============================================================================

CREATE OR REPLACE TABLE `pdm-ceasa.silver.ceasa_es` AS
WITH base_mapeada AS (
    SELECT
        data,
        CASE produto
            WHEN 'ABOBRINHA ITALIANA EXTRA' THEN 'abobrinha_italiana'
            WHEN 'BANANA MACA CLIM PRIM' THEN 'banana_maca'
            WHEN 'BATATA LISA AGATHA PRIM' THEN 'batata_inglesa'
            WHEN 'BATATA LISA ASTER.ESP' THEN 'batata_lisa'
            WHEN 'BERINJELA EXTRA' THEN 'berinjela'
            WHEN 'BETERRABA EXTRA' THEN 'beterraba'
            WHEN 'CENOURA EXTRA' THEN 'cenoura'
            WHEN 'CHUCHU EXTRA' THEN 'chuchu'
            WHEN 'COCO SECO' THEN 'coco_seco'
            WHEN 'COCO VERDE GRANDE' THEN 'coco_verde'
            WHEN 'LARANJA PERA TIPO 96 -140' THEN 'laranja_pera'
            WHEN 'LIMAO TAHITI T 256-324' THEN 'limao_taiti'
            WHEN 'MACA FUJI CAT. 1 T.135-150' THEN 'maca_fuji'
            WHEN 'MACA GALA CAT. 1 T. 135-150' THEN 'maca_gala'
            WHEN 'MAMAO FORMOSA' THEN 'mamao_formosa'
            WHEN 'MARACUJA AZEDO EXTRA AA' THEN 'maracuja_azedo'
            WHEN 'MELANCIA REDONDA GRAUDA' THEN 'melancia'
            WHEN 'MILHO VERDE COM PALHA' THEN 'milho_verde'
            WHEN 'MORANGO GRAUDO' THEN 'morango'
            WHEN 'PIMENTAO VERDE EXTRA A' THEN 'pimentao_verde'
            WHEN 'QUIABO EXTRA' THEN 'quiabo'
            WHEN 'REPOLHO HIBRIDO EXTRA' THEN 'repolho_verde'
            WHEN 'REPOLHO ROXO EXTRA' THEN 'repolho_roxo'
            WHEN 'TOMATE LONGA VIDA EXTRA A' THEN 'tomate_longa_vida'
            WHEN 'UVA ITALIA EXTRA' THEN 'uva_italia'
        END AS produto_canonico,
        CASE WHEN embalagem = 'UN 2,0 KG' THEN 2.0 ELSE 1.0 END AS qtd_kg,
        preco_minimo,
        preco_comum,
        preco_maximo
    FROM `pdm-ceasa.bronze.ceasa_es`
    WHERE mercado = 'CEASA GRANDE VITÓRIA'
      AND produto IN (
        'ABOBRINHA ITALIANA EXTRA', 'BANANA MACA CLIM PRIM', 'BATATA LISA AGATHA PRIM',
        'BATATA LISA ASTER.ESP', 'BERINJELA EXTRA', 'BETERRABA EXTRA', 'CENOURA EXTRA',
        'CHUCHU EXTRA', 'COCO SECO', 'COCO VERDE GRANDE',
        'LARANJA PERA TIPO 96 -140', 'LIMAO TAHITI T 256-324', 'MACA FUJI CAT. 1 T.135-150',
        'MACA GALA CAT. 1 T. 135-150', 'MAMAO FORMOSA', 'MARACUJA AZEDO EXTRA AA',
        'MELANCIA REDONDA GRAUDA', 'MILHO VERDE COM PALHA', 'MORANGO GRAUDO',
        'PIMENTAO VERDE EXTRA A', 'QUIABO EXTRA', 'REPOLHO HIBRIDO EXTRA',
        'REPOLHO ROXO EXTRA', 'TOMATE LONGA VIDA EXTRA A', 'UVA ITALIA EXTRA'
      )
),
base_precos_kg AS (
    SELECT
        data,
        produto_canonico,
        ROUND(AVG(preco_minimo / qtd_kg), 3) AS preco_minimo,
        ROUND(AVG(preco_comum / qtd_kg), 3) AS preco_comum,
        ROUND(AVG(preco_maximo / qtd_kg), 3) AS preco_maximo
    FROM base_mapeada
    GROUP BY data, produto_canonico
),
estatisticas AS (
    SELECT
        produto_canonico,
        AVG(preco_minimo) AS min_avg, STDDEV(preco_minimo) AS min_std,
        AVG(preco_comum) AS com_avg, STDDEV(preco_comum) AS com_std,
        AVG(preco_maximo) AS max_avg, STDDEV(preco_maximo) AS max_std
    FROM base_precos_kg
    GROUP BY produto_canonico
),
base_sem_outliers AS (
    SELECT
        p.data,
        p.produto_canonico,
        CASE
            WHEN p.preco_minimo < (e.min_avg - 3 * e.min_std) OR p.preco_minimo > (e.min_avg + 3 * e.min_std) THEN NULL
            ELSE p.preco_minimo
        END AS preco_minimo,
        CASE
            WHEN p.preco_comum < (e.com_avg - 3 * e.com_std) OR p.preco_comum > (e.com_avg + 3 * e.com_std) THEN NULL
            ELSE p.preco_comum
        END AS preco_comum,
        CASE
            WHEN p.preco_maximo < (e.max_avg - 3 * e.max_std) OR p.preco_maximo > (e.max_avg + 3 * e.max_std) THEN NULL
            ELSE p.preco_maximo
        END AS preco_maximo
    FROM base_precos_kg p
    JOIN estatisticas e ON p.produto_canonico = e.produto_canonico
),
intervalos AS (
    SELECT produto_canonico, MIN(data) AS data_inicio, MAX(data) AS data_fim
    FROM base_sem_outliers
    GROUP BY produto_canonico
),
grid_datas AS (
    SELECT
        i.produto_canonico,
        d AS data
    FROM intervalos i,
    UNNEST(GENERATE_DATE_ARRAY(i.data_inicio, i.data_fim, INTERVAL 1 DAY)) AS d
),
grid_com_dados AS (
    SELECT
        g.data,
        g.produto_canonico,
        b.preco_minimo,
        b.preco_comum,
        b.preco_maximo
    FROM grid_datas g
    LEFT JOIN base_sem_outliers b
      ON g.data = b.data AND g.produto_canonico = b.produto_canonico
),
pontos_interpolacao AS (
    SELECT
        data,
        produto_canonico,
        preco_minimo,
        preco_comum,
        preco_maximo,
        LAST_VALUE(preco_minimo IGNORE NULLS) OVER (w_prec) AS min_prev,
        FIRST_VALUE(preco_minimo IGNORE NULLS) OVER (w_foll) AS min_next,
        LAST_VALUE(CASE WHEN preco_minimo IS NOT NULL THEN data END IGNORE NULLS) OVER (w_prec) AS data_prev_min,
        FIRST_VALUE(CASE WHEN preco_minimo IS NOT NULL THEN data END IGNORE NULLS) OVER (w_foll) AS data_next_min,
        LAST_VALUE(preco_comum IGNORE NULLS) OVER (w_prec) AS com_prev,
        FIRST_VALUE(preco_comum IGNORE NULLS) OVER (w_foll) AS com_next,
        LAST_VALUE(CASE WHEN preco_comum IS NOT NULL THEN data END IGNORE NULLS) OVER (w_prec) AS data_prev_com,
        FIRST_VALUE(CASE WHEN preco_comum IS NOT NULL THEN data END IGNORE NULLS) OVER (w_foll) AS data_next_com,
        LAST_VALUE(preco_maximo IGNORE NULLS) OVER (w_prec) AS max_prev,
        FIRST_VALUE(preco_maximo IGNORE NULLS) OVER (w_foll) AS max_next,
        LAST_VALUE(CASE WHEN preco_maximo IS NOT NULL THEN data END IGNORE NULLS) OVER (w_prec) AS data_prev_max,
        FIRST_VALUE(CASE WHEN preco_maximo IS NOT NULL THEN data END IGNORE NULLS) OVER (w_foll) AS data_next_max
    FROM grid_com_dados
    WINDOW
        w_prec AS (PARTITION BY produto_canonico ORDER BY data ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
        w_foll AS (PARTITION BY produto_canonico ORDER BY data ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
),
precos_interpolados AS (
    SELECT
        data,
        produto_canonico,
        COALESCE(
            preco_minimo,
            min_prev + (min_next - min_prev) * (DATE_DIFF(data, data_prev_min, DAY) / NULLIF(DATE_DIFF(data_next_min, data_prev_min, DAY), 0)),
            min_prev,
            min_next
        ) AS preco_minimo,
        COALESCE(
            preco_comum,
            com_prev + (com_next - com_prev) * (DATE_DIFF(data, data_prev_com, DAY) / NULLIF(DATE_DIFF(data_next_com, data_prev_com, DAY), 0)),
            com_prev,
            com_next
        ) AS preco_comum,
        COALESCE(
            preco_maximo,
            max_prev + (max_next - max_prev) * (DATE_DIFF(data, data_prev_max, DAY) / NULLIF(DATE_DIFF(data_next_max, data_prev_max, DAY), 0)),
            max_prev,
            max_next
        ) AS preco_maximo
    FROM pontos_interpolacao
),
silver_sem_clima AS (
    SELECT
        data,
        EXTRACT(YEAR FROM data) AS ano,
        EXTRACT(MONTH FROM data) AS mes,
        EXTRACT(DAY FROM data) AS dia,
        'ES' AS ceasa,
        CASE
            WHEN produto_canonico IN (
                'banana_maca', 'coco_seco', 'coco_verde',
                'laranja_pera', 'limao_taiti', 'maca_fuji', 'maca_gala',
                'mamao_formosa', 'maracuja_azedo', 'melancia', 'morango', 'uva_italia'
            ) THEN 'fruta'
            ELSE 'verdura'
        END AS grupo_canonico,
        produto_canonico,
        ROUND(preco_minimo, 3) AS preco_minimo,
        ROUND(preco_comum, 3) AS preco_comum,
        ROUND(preco_maximo, 3) AS preco_maximo
    FROM precos_interpolados
)
SELECT
    s.*,
    cl.temp_media_3d, cl.umidade_media_3d, cl.nebulosidade_media_3d, cl.precipitacao_mm_3d, cl.vento_max_kmh_3d,
    cl.temp_media_7d, cl.umidade_media_7d, cl.nebulosidade_media_7d, cl.precipitacao_mm_7d, cl.vento_max_kmh_7d,
    cl.temp_media_14d, cl.umidade_media_14d, cl.nebulosidade_media_14d, cl.precipitacao_mm_14d, cl.vento_max_kmh_14d,
    cl.temp_media_30d, cl.umidade_media_30d, cl.nebulosidade_media_30d, cl.precipitacao_mm_30d, cl.vento_max_kmh_30d,
    cl.temp_media_60d, cl.umidade_media_60d, cl.nebulosidade_media_60d, cl.precipitacao_mm_60d, cl.vento_max_kmh_60d
FROM silver_sem_clima s
LEFT JOIN `pdm-ceasa.silver.clima_historico` cl
  ON s.data = cl.data AND cl.estado = 'ES'
ORDER BY s.produto_canonico, s.data;
