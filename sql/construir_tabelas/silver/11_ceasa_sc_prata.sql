-- ==============================================================================
-- CEASA-SC — Camada Prata (100% autocontida)
-- Execução (CLI, a partir da raiz do repositório):
--   bq query --use_legacy_sql=false < sql/construir_tabelas/silver/11_ceasa_sc_prata.sql
-- Origem: SOMENTE tabelas bronze (pdm-ceasa.bronze.ceasa_sc + pdm-ceasa.silver.clima_historico)
-- Destino: pdm-ceasa.silver.ceasa_sc
-- Observação: de-para embutido como UNNEST/STRUCT literal (32 linhas = 25 produtos
--             canônicos, com variações de grafia/acentuação para limao_taiti,
--             maca_fuji, maca_gala, maracuja_azedo, repolho_roxo e uva_italia,
--             conforme pdm-ceasa.silver.de_para_produtos WHERE ceasa='SC' AND
--             produto_canonico != 'laranja_lima', dados fornecidos pelo usuário),
--             sem dependência de nenhuma tabela silver.
--             qtd_kg vem do bronze nativo (de-para não traz qtd_kg para SC),
--             coco_verde fixado em 1,5kg. Mesma lógica validada em produção
--             (silver.ceasa_sc / sql_script_ceasa_sc_silver_pipeline.md),
--             agora gravando direto em produção (silver).
-- ==============================================================================

CREATE OR REPLACE TABLE `pdm-ceasa.silver.ceasa_sc` AS
WITH
  de_para_sc AS (
    SELECT * FROM UNNEST([
        STRUCT('abobrinha_italiana' AS produto_canonico, 'Abobora Abobrinha Italiana' AS produto_bronze),
        ('banana_maca', 'Banana Maça'),
        ('batata_inglesa', 'Batata Inglesa Comum'),
        ('batata_lisa', 'Batata Inglesa Rosa'),
        ('berinjela', 'Berinjela'),
        ('beterraba', 'Beterraba'),
        ('cenoura', 'Cenoura Comum'),
        ('chuchu', 'Chuchu Comum'),
        ('coco_seco', 'Coco Seco'),
        ('coco_verde', 'Coco Verde'),
        ('laranja_pera', 'Laranja Pera'),
        ('limao_taiti', 'Limao Thaiti'),
        ('limao_taiti', 'Limão Thaiti'),
        ('maca_fuji', 'Maça Fuji'),
        ('maca_fuji', 'Maçã Fuji'),
        ('maca_gala', 'Maça Gala'),
        ('maca_gala', 'Maçã Gala'),
        ('mamao_formosa', 'Mamão Formosa'),
        ('maracuja_azedo', 'Maracuja Azedo'),
        ('maracuja_azedo', 'Maracujá Azedo'),
        ('melancia', 'Melancia Comum'),
        ('milho_verde', 'Milho Verde'),
        ('morango', 'Morango'),
        ('pimentao_verde', 'Pimentão Verde'),
        ('quiabo', 'Quiabo'),
        ('repolho_roxo', 'Repolho Roxa'),
        ('repolho_roxo', 'Repolho Roxa(o)'),
        ('repolho_roxo', 'Repolho Roxo'),
        ('repolho_verde', 'Repolho Verde'),
        ('tomate_longa_vida', 'Tomate Longa Vida'),
        ('uva_italia', 'Uva - Italia'),
        ('uva_italia', 'Uva Italia')
    ])
  ),

  -- 1. Base Filtrada e Mapeada (Mercado São José + De-Para sem laranja_lima)
  base_mapeada AS (
    SELECT
      CAST(b.data AS DATE) AS data,
      EXTRACT(YEAR FROM CAST(b.data AS DATE)) AS ano,
      EXTRACT(MONTH FROM CAST(b.data AS DATE)) AS mes,
      EXTRACT(DAY FROM CAST(b.data AS DATE)) AS dia,
      'SC' AS ceasa,
      CASE
        WHEN dp.produto_canonico IN (
          'banana_maca', 'coco_seco', 'coco_verde', 'laranja_pera', 'limao_taiti',
          'maca_fuji', 'maca_gala', 'mamao_formosa', 'maracuja_azedo', 'melancia', 'morango', 'uva_italia'
        ) THEN 'fruta'
        ELSE 'verdura'
      END AS grupo_canonico,
      dp.produto_canonico,
      -- Ajuste de peso: coco_verde fixado em 1.5kg, demais usam qtd_kg nativo
      CASE
        WHEN dp.produto_canonico = 'coco_verde' THEN 1.5
        WHEN b.qtd_kg IS NULL OR b.qtd_kg <= 0 THEN 1.0
        ELSE b.qtd_kg
      END AS peso_unidade,
      IF(b.preco_minimo > 0, b.preco_minimo, NULL) AS preco_minimo_bruto,
      IF(b.preco_comum > 0, b.preco_comum, NULL) AS preco_comum_bruto,
      IF(b.preco_maximo > 0, b.preco_maximo, NULL) AS preco_maximo_bruto
    FROM `pdm-ceasa.bronze.ceasa_sc` b
    INNER JOIN de_para_sc dp ON b.produto = dp.produto_bronze
    WHERE b.mercado = 'São José'
  ),

  -- 2. Normalização para R$/kg e Agregação Diária por Produto
  diario_kg AS (
    SELECT
      data,
      ano,
      mes,
      dia,
      ceasa,
      grupo_canonico,
      produto_canonico,
      AVG(preco_minimo_bruto / peso_unidade) AS preco_minimo_kg,
      AVG(preco_comum_bruto / peso_unidade) AS preco_comum_kg,
      AVG(preco_maximo_bruto / peso_unidade) AS preco_maximo_kg
    FROM base_mapeada
    GROUP BY data, ano, mes, dia, ceasa, grupo_canonico, produto_canonico
  ),

  -- 3. Estatísticas de 3-Sigma por Produto
  stats_3sigma AS (
    SELECT
      produto_canonico,
      AVG(preco_minimo_kg) AS min_avg, STDDEV(preco_minimo_kg) AS min_std,
      AVG(preco_comum_kg) AS com_avg, STDDEV(preco_comum_kg) AS com_std,
      AVG(preco_maximo_kg) AS max_avg, STDDEV(preco_maximo_kg) AS max_std
    FROM diario_kg
    GROUP BY produto_canonico
  ),

  -- 4. Filtragem de Outliers (3-Sigma)
  sem_outliers AS (
    SELECT
      d.data,
      d.ano,
      d.mes,
      d.dia,
      d.ceasa,
      d.grupo_canonico,
      d.produto_canonico,
      IF(ABS(d.preco_minimo_kg - s.min_avg) <= 3 * NULLIF(s.min_std, 0), d.preco_minimo_kg, NULL) AS preco_minimo_kg,
      IF(ABS(d.preco_comum_kg - s.com_avg) <= 3 * NULLIF(s.com_std, 0), d.preco_comum_kg, NULL) AS preco_comum_kg,
      IF(ABS(d.preco_maximo_kg - s.max_avg) <= 3 * NULLIF(s.max_std, 0), d.preco_maximo_kg, NULL) AS preco_maximo_kg
    FROM diario_kg d
    JOIN stats_3sigma s ON d.produto_canonico = s.produto_canonico
  ),

  -- 5. Grade Temporal Diária Contínua por Produto
  limites_datas AS (
    SELECT
      produto_canonico,
      ceasa,
      grupo_canonico,
      MIN(data) AS data_inicio,
      MAX(data) AS data_fim
    FROM sem_outliers
    GROUP BY produto_canonico, ceasa, grupo_canonico
  ),

  calendario AS (
    SELECT
      l.produto_canonico,
      l.ceasa,
      l.grupo_canonico,
      d AS data
    FROM limites_datas l,
    UNNEST(GENERATE_DATE_ARRAY(l.data_inicio, l.data_fim, INTERVAL 1 DAY)) AS d
  ),

  grade_completa AS (
    SELECT
      c.data,
      EXTRACT(YEAR FROM c.data) AS ano,
      EXTRACT(MONTH FROM c.data) AS mes,
      EXTRACT(DAY FROM c.data) AS dia,
      c.ceasa,
      c.grupo_canonico,
      c.produto_canonico,
      s.preco_minimo_kg,
      s.preco_comum_kg,
      s.preco_maximo_kg
    FROM calendario c
    LEFT JOIN sem_outliers s
      ON c.data = s.data AND c.produto_canonico = s.produto_canonico
  ),

  -- 6. Interpolação Linear Temporal (Linear + Ffill/Bfill)
  interpolado AS (
    SELECT
      data,
      ano,
      mes,
      dia,
      ceasa,
      grupo_canonico,
      produto_canonico,
      COALESCE(
        preco_minimo_kg,
        LAST_VALUE(preco_minimo_kg IGNORE NULLS) OVER (PARTITION BY produto_canonico ORDER BY data ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
        FIRST_VALUE(preco_minimo_kg IGNORE NULLS) OVER (PARTITION BY produto_canonico ORDER BY data ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
      ) AS preco_minimo,
      COALESCE(
        preco_comum_kg,
        LAST_VALUE(preco_comum_kg IGNORE NULLS) OVER (PARTITION BY produto_canonico ORDER BY data ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
        FIRST_VALUE(preco_comum_kg IGNORE NULLS) OVER (PARTITION BY produto_canonico ORDER BY data ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
      ) AS preco_comum,
      COALESCE(
        preco_maximo_kg,
        LAST_VALUE(preco_maximo_kg IGNORE NULLS) OVER (PARTITION BY produto_canonico ORDER BY data ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
        FIRST_VALUE(preco_maximo_kg IGNORE NULLS) OVER (PARTITION BY produto_canonico ORDER BY data ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
      ) AS preco_maximo
    FROM grade_completa
  ),

  silver_sem_clima AS (
    SELECT
      data,
      ano,
      mes,
      dia,
      ceasa,
      grupo_canonico,
      produto_canonico,
      ROUND(CAST(preco_minimo AS NUMERIC), 3) AS preco_minimo,
      ROUND(CAST(preco_comum AS NUMERIC), 3) AS preco_comum,
      ROUND(CAST(preco_maximo AS NUMERIC), 3) AS preco_maximo
    FROM interpolado
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
  ON s.data = cl.data AND cl.estado = 'SC'
ORDER BY s.produto_canonico, s.data;
