-- ==============================================================================
-- Pipeline Bronze -> Prata: CEASA-GO + Clima
-- Execução (CLI, a partir da raiz do repositório):
--   bq query --use_legacy_sql=false < sql/construir_tabelas/silver/10_ceasa_go_prata.sql
-- Origem:  pdm-ceasa.bronze.ceasa_go, pdm-ceasa.silver.clima_historico
-- Destino: pdm-ceasa.silver.ceasa_go
-- Autocontido: não depende de nenhuma tabela silver.ceasa_* já existente.
-- ==============================================================================

CREATE OR REPLACE TABLE `pdm-ceasa.silver.ceasa_go` AS
WITH
  -- 1. Bronze sem duplicatas de ingestão (mesmo conteúdo, arquivo de origem diferente)
  bronze_dedup AS (
    SELECT DISTINCT
      data, ano, mes, dia, grupo, categoria, produto, embalagem, qtd_kg, classe,
      preco_comum, preco_maximo, preco_minimo
    FROM `pdm-ceasa.bronze.ceasa_go`
  ),

  -- 2. De-para (produto_bronze corrigido para os literais reais da bronze) + classe 1 + embalagem não nula
  --    Embutido aqui em vez de depender de silver.de_para_produtos, para o arquivo ser autocontido
  de_para_go AS (
    SELECT * FROM UNNEST([
      STRUCT('abobrinha_italiana' AS produto_canonico, 'ABOBORA VERDE ITALIANA' AS produto_bronze),
      ('banana_maca', 'BANANA MACA'),
      ('batata_inglesa', 'BATATA COMUM DIVERSAS'),
      ('batata_lisa', 'BATATA LISA (ACHATI-BINJ)'),
      ('berinjela', 'BERINJELA'),
      ('beterraba', 'BETERRABA'),
      ('cenoura', 'CENOURA'),
      ('chuchu', 'CHUCHU'),
      ('coco_seco', 'COCO SECO'),
      ('coco_verde', 'COCO VERDE'),
      ('laranja_pera', 'LARANJA PERA RIO'),
      ('limao_taiti', 'LIMAO TAHITI (SP)'),
      ('maca_fuji', 'MACA NACIONAL FUGI (CART) T150'),
      ('maca_gala', 'MACA NAICONAL GALA (CART.) T150'),
      ('mamao_formosa', 'MAMAO FORMOSA'),
      ('maracuja_azedo', 'MARACUJA AZEDO'),
      ('melancia', 'MELANCIA'),
      ('milho_verde', 'MILHO VERDE'),
      ('morango', 'MORANGO'),
      ('pimentao_verde', 'PIMENTAO'),
      ('quiabo', 'QUIABO'),
      ('repolho_roxo', 'REPOLHO ROXO'),
      ('repolho_verde', 'REPOLHO'),
      ('tomate_longa_vida', 'TOMATE LONGA VIDA'),
      ('uva_italia', 'UVA ITALIA')
    ])
  ),

  base_mapeada AS (
    SELECT
      b.data,
      dp.produto_canonico,
      b.embalagem,
      b.qtd_kg,
      b.preco_minimo,
      b.preco_comum,
      b.preco_maximo
    FROM bronze_dedup b
    INNER JOIN de_para_go dp ON b.produto = dp.produto_bronze
    WHERE b.classe = '1'
      AND b.embalagem IS NOT NULL
  ),

  -- 3. Resolução de conflito de embalagem/peso: repolho_roxo (corte temporal fixo em 2024-02-01)
  --    e batata_lisa (maioria mensal) — demais produtos passam direto
  batata_lisa_mensal AS (
    SELECT
      FORMAT_DATE('%Y-%m', data) AS ano_mes,
      qtd_kg,
      COUNT(*) AS qtd_obs
    FROM base_mapeada
    WHERE produto_canonico = 'batata_lisa'
    GROUP BY ano_mes, qtd_kg
  ),
  batata_lisa_peso_vencedor AS (
    SELECT ano_mes, qtd_kg AS peso_vencedor
    FROM (
      SELECT ano_mes, qtd_kg,
             ROW_NUMBER() OVER (PARTITION BY ano_mes ORDER BY qtd_obs DESC) AS rn
      FROM batata_lisa_mensal
    )
    WHERE rn = 1
  ),

  base_resolvida AS (
    SELECT b.*
    FROM base_mapeada b
    WHERE b.produto_canonico = 'repolho_roxo'
      AND (
        (b.data < '2024-02-01' AND b.qtd_kg = 26.0) OR
        (b.data >= '2024-02-01' AND b.qtd_kg = 22.0)
      )

    UNION ALL

    SELECT b.*
    FROM base_mapeada b
    JOIN batata_lisa_peso_vencedor v
      ON FORMAT_DATE('%Y-%m', b.data) = v.ano_mes
    WHERE b.produto_canonico = 'batata_lisa'
      AND b.qtd_kg = v.peso_vencedor

    UNION ALL

    SELECT *
    FROM base_mapeada
    WHERE produto_canonico NOT IN ('repolho_roxo', 'batata_lisa')
  ),

  -- 4. Conversão para R$/kg (preco_kg nativo da bronze nunca é usado) e agregação diária
  base_precos_kg AS (
    SELECT
      data,
      produto_canonico,
      AVG(IF(preco_minimo > 0, preco_minimo, NULL) / qtd_kg) AS preco_minimo,
      AVG(IF(preco_comum > 0, preco_comum, NULL) / qtd_kg) AS preco_comum,
      AVG(IF(preco_maximo > 0, preco_maximo, NULL) / qtd_kg) AS preco_maximo
    FROM base_resolvida
    GROUP BY data, produto_canonico
  ),

  -- 5. Estatísticas de 3-Sigma por produto
  estatisticas AS (
    SELECT
      produto_canonico,
      AVG(preco_minimo) AS min_avg, STDDEV(preco_minimo) AS min_std,
      AVG(preco_comum) AS com_avg, STDDEV(preco_comum) AS com_std,
      AVG(preco_maximo) AS max_avg, STDDEV(preco_maximo) AS max_std
    FROM base_precos_kg
    GROUP BY produto_canonico
  ),

  -- 6. Anulação de outliers fora de 3-Sigma
  base_sem_outliers AS (
    SELECT
      p.data,
      p.produto_canonico,
      CASE WHEN p.preco_minimo < (e.min_avg - 3 * e.min_std) OR p.preco_minimo > (e.min_avg + 3 * e.min_std) THEN NULL ELSE p.preco_minimo END AS preco_minimo,
      CASE WHEN p.preco_comum < (e.com_avg - 3 * e.com_std) OR p.preco_comum > (e.com_avg + 3 * e.com_std) THEN NULL ELSE p.preco_comum END AS preco_comum,
      CASE WHEN p.preco_maximo < (e.max_avg - 3 * e.max_std) OR p.preco_maximo > (e.max_avg + 3 * e.max_std) THEN NULL ELSE p.preco_maximo END AS preco_maximo
    FROM base_precos_kg p
    JOIN estatisticas e ON p.produto_canonico = e.produto_canonico
  ),

  -- 7. Grade temporal diária contínua por produto
  intervalos AS (
    SELECT produto_canonico, MIN(data) AS data_inicio, MAX(data) AS data_fim
    FROM base_sem_outliers
    GROUP BY produto_canonico
  ),
  grid_datas AS (
    SELECT i.produto_canonico, d AS data
    FROM intervalos i,
    UNNEST(GENERATE_DATE_ARRAY(i.data_inicio, i.data_fim, INTERVAL 1 DAY)) AS d
  ),
  grid_com_dados AS (
    SELECT g.data, g.produto_canonico, b.preco_minimo, b.preco_comum, b.preco_maximo
    FROM grid_datas g
    LEFT JOIN base_sem_outliers b
      ON g.data = b.data AND g.produto_canonico = b.produto_canonico
  ),

  -- 8. Interpolação linear temporal (com ffill/bfill nas bordas)
  pontos_interpolacao AS (
    SELECT
      data, produto_canonico, preco_minimo, preco_comum, preco_maximo,
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
        min_prev, min_next
      ) AS preco_minimo,
      COALESCE(
        preco_comum,
        com_prev + (com_next - com_prev) * (DATE_DIFF(data, data_prev_com, DAY) / NULLIF(DATE_DIFF(data_next_com, data_prev_com, DAY), 0)),
        com_prev, com_next
      ) AS preco_comum,
      COALESCE(
        preco_maximo,
        max_prev + (max_next - max_prev) * (DATE_DIFF(data, data_prev_max, DAY) / NULLIF(DATE_DIFF(data_next_max, data_prev_max, DAY), 0)),
        max_prev, max_next
      ) AS preco_maximo
    FROM pontos_interpolacao
  ),

  -- 9. Esquema padrão Silver (sem clima ainda)
  silver_sem_clima AS (
    SELECT
      data,
      EXTRACT(YEAR FROM data) AS ano,
      EXTRACT(MONTH FROM data) AS mes,
      EXTRACT(DAY FROM data) AS dia,
      'GO' AS ceasa,
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

-- 10. Junção final com clima histórico (dado tal como está na silver.clima_historico)
SELECT
  s.*,
  cl.temp_media_3d, cl.umidade_media_3d, cl.nebulosidade_media_3d, cl.precipitacao_mm_3d, cl.vento_max_kmh_3d,
  cl.temp_media_7d, cl.umidade_media_7d, cl.nebulosidade_media_7d, cl.precipitacao_mm_7d, cl.vento_max_kmh_7d,
  cl.temp_media_14d, cl.umidade_media_14d, cl.nebulosidade_media_14d, cl.precipitacao_mm_14d, cl.vento_max_kmh_14d,
  cl.temp_media_30d, cl.umidade_media_30d, cl.nebulosidade_media_30d, cl.precipitacao_mm_30d, cl.vento_max_kmh_30d,
  cl.temp_media_60d, cl.umidade_media_60d, cl.nebulosidade_media_60d, cl.precipitacao_mm_60d, cl.vento_max_kmh_60d
FROM silver_sem_clima s
LEFT JOIN `pdm-ceasa.silver.clima_historico` cl
  ON s.data = cl.data AND cl.estado = 'GO'
ORDER BY s.produto_canonico, s.data;
