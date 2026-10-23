-- ==============================================================================
-- CEASA-MS — Camada Prata (100% autocontida)
-- Execução (CLI, a partir da raiz do repositório):
--   bq query --use_legacy_sql=false < sql/construir_tabelas/silver/12_ceasa_ms_prata.sql
-- Origem: SOMENTE tabelas bronze (pdm-ceasa.bronze.ceasa_ms + pdm-ceasa.silver.clima_historico)
-- Destino: pdm-ceasa.silver.ceasa_ms
-- Observação: de-para embutido como UNNEST/STRUCT literal (25 produtos, conforme
--             pdm-ceasa.silver.de_para_produtos WHERE ceasa='MS' AND produto_canonico != 'laranja_lima',
--             dados fornecidos pelo usuário), sem dependência de nenhuma tabela silver.
--             qtd_kg embutido junto (vem do de-para, não do bronze, igual produção).
--             Mesma lógica validada em produção (silver.ceasa_ms / gemini-code-1792439209389.sql),
--             agora gravando direto em produção (silver).
-- ==============================================================================

CREATE OR REPLACE TABLE `pdm-ceasa.silver.ceasa_ms` AS
WITH de_para_ms AS (
    SELECT * FROM UNNEST([
        STRUCT('abobrinha_italiana' AS produto_canonico, 'Abobrinha Italiana - (MS/SP)' AS produto_bronze, 22.5 AS qtd_kg),
        ('banana_maca', 'Banana Maçã - Primeira / Climatizada', 23.0),
        ('batata_inglesa', 'Batata Comum Especial (SP/PR/MG)', 50.0),
        ('batata_lisa', 'Batata Roxa / Primeira (MS/PR)', 25.0),
        ('berinjela', 'Berinjela Primeira (MS/PR)', 13.0),
        ('beterraba', 'Beterraba Primeira (MS/PR)', 25.0),
        ('cenoura', 'Cenoura Primeira (MS/PR)', 20.0),
        ('chuchu', 'Chuchu Primeira (MS/PR)', 20.0),
        ('coco_seco', 'Coco Seco', 20.0),
        ('coco_verde', 'Coco Verde', 1.5),
        ('laranja_pera', 'Laranja Pêra (MS/SP/PR)', 1.0),
        ('limao_taiti', 'Limão Thayti (SP)', 20.0),
        ('maca_fuji', 'Maçã Fuji Comercial TP80 / 135', 18.0),
        ('maca_gala', 'Maçã Gala Comercial TP80 / 135', 18.0),
        ('mamao_formosa', 'Mamão Formosa (SP/BA)', 19.0),
        ('maracuja_azedo', 'Maracujá Azedo (SP/PR)', 11.0),
        ('melancia', 'Melancia (GO/MS/SP/RS)', 1.0),
        ('milho_verde', 'Milho Verde (MS/SP)', 15.0),
        ('morango', 'Morango', 1.5),
        ('pimentao_verde', 'Pimentão Verde Extra (SP/PR)', 12.0),
        ('quiabo', 'Quiabo Primeira (MS/SP)', 15.0),
        ('repolho_roxo', 'Repolho Roxo Primeira (MS)', 30.0),
        ('repolho_verde', 'Repolho Verde Primeira (MS/PR)', 30.0),
        ('tomate_longa_vida', 'Tomate Longa Vida Primeira (MS/PR)', 25.0),
        ('uva_italia', 'Uva Itália (SP/PR)', 8.0)
    ])
),
base_mapeada AS (
    -- Mapeamento bronze e anulação de cotações <= 0
    SELECT
        b.data,
        dp.produto_canonico,
        COALESCE(dp.qtd_kg, 1.0) AS qtd_kg_tratado,
        CASE WHEN b.preco_minimo <= 0 THEN NULL ELSE b.preco_minimo END AS preco_minimo,
        CASE WHEN b.preco_comum <= 0 THEN NULL ELSE b.preco_comum END AS preco_comum,
        CASE WHEN b.preco_maximo <= 0 THEN NULL ELSE b.preco_maximo END AS preco_maximo
    FROM `pdm-ceasa.bronze.ceasa_ms` b
    JOIN de_para_ms dp ON b.produto = dp.produto_bronze
),
base_precos_kg AS (
    -- Converter cotações para R$/kg
    SELECT
        data,
        produto_canonico,
        ROUND(AVG(preco_minimo / qtd_kg_tratado), 3) AS preco_minimo,
        ROUND(AVG(preco_comum / qtd_kg_tratado), 3) AS preco_comum,
        ROUND(AVG(preco_maximo / qtd_kg_tratado), 3) AS preco_maximo
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
        'MS' AS ceasa,
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
  ON s.data = cl.data AND cl.estado = 'MS'
ORDER BY s.produto_canonico, s.data;
