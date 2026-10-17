-- Conferencia das tabelas Bronze por sede (bronze.ceasa_go, _ms, _sc, _mg, _es),
-- alimentadas por sql/construir_tabelas/bronze/02_ a 06_, e do manifesto dos
-- brutos (07_manifesto_brutos.sql).

-- Tamanho, boletins, faixa de datas e nulos, por tabela
SELECT 'ceasa_go' AS tabela, COUNT(*) AS linhas, COUNT(DISTINCT arquivo) AS boletins,
       MIN(data) AS data_minima, MAX(data) AS data_maxima,
       COUNTIF(data IS NULL) AS data_nula, COUNTIF(produto IS NULL) AS produto_nulo,
       COUNTIF(preco_comum IS NULL) AS preco_comum_nulo, COUNTIF(arquivo IS NULL) AS arquivo_nulo
FROM `bronze.ceasa_go`
UNION ALL
SELECT 'ceasa_ms', COUNT(*), COUNT(DISTINCT arquivo), MIN(data), MAX(data),
       COUNTIF(data IS NULL), COUNTIF(produto IS NULL), COUNTIF(preco_comum IS NULL), COUNTIF(arquivo IS NULL)
FROM `bronze.ceasa_ms`
UNION ALL
SELECT 'ceasa_sc', COUNT(*), COUNT(DISTINCT arquivo), MIN(data), MAX(data),
       COUNTIF(data IS NULL), COUNTIF(produto IS NULL), COUNTIF(preco_comum IS NULL), COUNTIF(arquivo IS NULL)
FROM `bronze.ceasa_sc`
UNION ALL
SELECT 'ceasa_mg', COUNT(*), COUNT(DISTINCT arquivo), MIN(data), MAX(data),
       COUNTIF(data IS NULL), COUNTIF(produto IS NULL), COUNTIF(preco_comum IS NULL), COUNTIF(arquivo IS NULL)
FROM `bronze.ceasa_mg`
UNION ALL
SELECT 'ceasa_es', COUNT(*), COUNT(DISTINCT arquivo), MIN(data), MAX(data),
       COUNTIF(data IS NULL), COUNTIF(produto IS NULL), COUNTIF(preco_comum IS NULL), COUNTIF(arquivo IS NULL)
FROM `bronze.ceasa_es`
ORDER BY tabela;

-- Prova do MERGE: todo boletim do ultimo scraping (stg_ceasa_<uf>) tem que
-- estar na tabela com exatamente o mesmo numero de linhas. Esperado: 0 em
-- todas as sedes. Diferente de 0 = boletim faltando ou duplicado.
WITH divergencias AS (
  SELECT 'ceasa_go' AS tabela, s.arquivo
  FROM (SELECT arquivo, COUNT(*) AS n FROM `bronze.stg_ceasa_go` GROUP BY arquivo) AS s
  LEFT JOIN (SELECT arquivo, COUNT(*) AS n FROM `bronze.ceasa_go` GROUP BY arquivo) AS t USING (arquivo)
  WHERE t.n IS NULL OR t.n != s.n
  UNION ALL
  SELECT 'ceasa_ms', s.arquivo
  FROM (SELECT arquivo, COUNT(*) AS n FROM `bronze.stg_ceasa_ms` GROUP BY arquivo) AS s
  LEFT JOIN (SELECT arquivo, COUNT(*) AS n FROM `bronze.ceasa_ms` GROUP BY arquivo) AS t USING (arquivo)
  WHERE t.n IS NULL OR t.n != s.n
  UNION ALL
  SELECT 'ceasa_sc', s.arquivo
  FROM (SELECT arquivo, COUNT(*) AS n FROM `bronze.stg_ceasa_sc` GROUP BY arquivo) AS s
  LEFT JOIN (SELECT arquivo, COUNT(*) AS n FROM `bronze.ceasa_sc` GROUP BY arquivo) AS t USING (arquivo)
  WHERE t.n IS NULL OR t.n != s.n
  UNION ALL
  SELECT 'ceasa_mg', s.arquivo
  FROM (SELECT arquivo, COUNT(*) AS n FROM `bronze.stg_ceasa_mg` GROUP BY arquivo) AS s
  LEFT JOIN (SELECT arquivo, COUNT(*) AS n FROM `bronze.ceasa_mg` GROUP BY arquivo) AS t USING (arquivo)
  WHERE t.n IS NULL OR t.n != s.n
  UNION ALL
  SELECT 'ceasa_es', s.arquivo
  FROM (SELECT arquivo, COUNT(*) AS n FROM `bronze.stg_ceasa_es` GROUP BY arquivo) AS s
  LEFT JOIN (SELECT arquivo, COUNT(*) AS n FROM `bronze.ceasa_es` GROUP BY arquivo) AS t USING (arquivo)
  WHERE t.n IS NULL OR t.n != s.n
)
SELECT tabela, COUNT(arquivo) AS boletins_divergentes
FROM (SELECT 'ceasa_go' AS tabela UNION ALL SELECT 'ceasa_ms' UNION ALL SELECT 'ceasa_sc'
      UNION ALL SELECT 'ceasa_mg' UNION ALL SELECT 'ceasa_es') AS todas
LEFT JOIN divergencias USING (tabela)
GROUP BY tabela
ORDER BY tabela;

-- Conferencia de duas vias: brutos no bucket (bronze.manifesto_brutos, de
-- 07_manifesto_brutos.sql) contra boletins no BigQuery. A ligacao e o caminho
-- do bruto; na MS, arquivo leva "#<aba>" no fim e varias abas sao o mesmo bruto.
--   so_no_bucket    bruto sem nenhuma linha na tabela. Esperado: so as falhas
--                   conhecidas do extrator (na GO, os 2 boletins semanais) e
--                   boletim publicado sem cotacao. Mais que isso = carga
--                   pendente ou boletim perdido; ver o log do extrator.
--   so_no_bigquery  linha na tabela sem bruto que a comprove: historico
--                   anterior ao repositorio ou bruto apagado do bucket. Nao e
--                   apagado automaticamente. Um numero alto junto de um
--                   so_no_bucket alto indica formato de arquivo diferente
--                   entre as linhas antigas e os coletores.
WITH
bucket AS (
  SELECT DISTINCT sede, caminho FROM `bronze.manifesto_brutos`
),
bigquery AS (
  SELECT DISTINCT sede, REGEXP_REPLACE(arquivo, r'#[0-9]+$', '') AS caminho
  FROM (
    SELECT 'go' AS sede, arquivo FROM `bronze.ceasa_go`
    UNION ALL SELECT 'ms', arquivo FROM `bronze.ceasa_ms`
    UNION ALL SELECT 'sc', arquivo FROM `bronze.ceasa_sc`
    UNION ALL SELECT 'mg', arquivo FROM `bronze.ceasa_mg`
    UNION ALL SELECT 'es', arquivo FROM `bronze.ceasa_es`
  )
  WHERE arquivo IS NOT NULL
)
SELECT sede,
       COUNTIF(b.caminho IS NOT NULL) AS brutos_no_bucket,
       COUNTIF(q.caminho IS NOT NULL) AS brutos_no_bigquery,
       COUNTIF(b.caminho IS NOT NULL AND q.caminho IS NOT NULL) AS nos_dois,
       COUNTIF(q.caminho IS NULL) AS so_no_bucket,
       COUNTIF(b.caminho IS NULL) AS so_no_bigquery
FROM bucket AS b
FULL OUTER JOIN bigquery AS q USING (sede, caminho)
GROUP BY sede
ORDER BY sede;

-- Detalhe do que ficou so no bucket, para investigar (ate 50 por sede).
WITH bigquery AS (
  SELECT DISTINCT sede, REGEXP_REPLACE(arquivo, r'#[0-9]+$', '') AS caminho
  FROM (
    SELECT 'go' AS sede, arquivo FROM `bronze.ceasa_go`
    UNION ALL SELECT 'ms', arquivo FROM `bronze.ceasa_ms`
    UNION ALL SELECT 'sc', arquivo FROM `bronze.ceasa_sc`
    UNION ALL SELECT 'mg', arquivo FROM `bronze.ceasa_mg`
    UNION ALL SELECT 'es', arquivo FROM `bronze.ceasa_es`
  )
  WHERE arquivo IS NOT NULL
)
SELECT b.sede, b.caminho
FROM `bronze.manifesto_brutos` AS b
LEFT JOIN bigquery AS q USING (sede, caminho)
WHERE q.caminho IS NULL
QUALIFY ROW_NUMBER() OVER (PARTITION BY b.sede ORDER BY b.caminho) <= 50
ORDER BY b.sede, b.caminho;
