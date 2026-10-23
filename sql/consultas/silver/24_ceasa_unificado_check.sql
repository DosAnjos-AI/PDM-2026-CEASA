-- Conferencia de sql/construir_tabelas/silver/15_ceasa_unificado.sql.
-- Faz: prova que o UNION ALL preserva a soma de linhas das 5 tabelas de
-- estado (por ceasa e no total), reporta produtos, periodo, chaves
-- duplicadas e nulos nos precos.
-- Nao faz: nao cria nem substitui nenhuma tabela.

-- linhas por ceasa: origem x unificado (esperado: iguais em todas)
WITH origem AS (
  SELECT 'GO' AS ceasa, COUNT(*) AS linhas_origem FROM `pdm-ceasa.silver.ceasa_go`
  UNION ALL SELECT 'SC', COUNT(*) FROM `pdm-ceasa.silver.ceasa_sc`
  UNION ALL SELECT 'MS', COUNT(*) FROM `pdm-ceasa.silver.ceasa_ms`
  UNION ALL SELECT 'MG', COUNT(*) FROM `pdm-ceasa.silver.ceasa_mg`
  UNION ALL SELECT 'ES', COUNT(*) FROM `pdm-ceasa.silver.ceasa_es`
),
unificado AS (
  SELECT
    ceasa,
    COUNT(*) AS linhas_unificado,
    COUNT(DISTINCT produto_canonico) AS produtos_distintos,
    MIN(data) AS data_min,
    MAX(data) AS data_max
  FROM `pdm-ceasa.silver.ceasa_unificado`
  GROUP BY ceasa
)
SELECT
  COALESCE(o.ceasa, u.ceasa) AS ceasa,
  o.linhas_origem,
  u.linhas_unificado,
  u.produtos_distintos,
  u.data_min,
  u.data_max
FROM origem AS o
FULL OUTER JOIN unificado AS u ON u.ceasa = o.ceasa
ORDER BY ceasa;

-- visao geral
SELECT
  COUNT(*) AS linhas,
  COUNT(DISTINCT produto_canonico) AS produtos_distintos,
  COUNT(DISTINCT ceasa) AS ceasas_distintas,
  MIN(data) AS data_min,
  MAX(data) AS data_max
FROM `pdm-ceasa.silver.ceasa_unificado`;

-- chaves duplicadas (esperado: 0)
SELECT COUNT(*) AS chaves_duplicadas
FROM (
  SELECT ceasa, produto_canonico, data, COUNT(*) AS n
  FROM `pdm-ceasa.silver.ceasa_unificado`
  GROUP BY ceasa, produto_canonico, data
  HAVING n > 1
);

-- nulos nos precos e linhas sem clima, por ceasa
SELECT
  ceasa,
  COUNTIF(preco_minimo IS NULL) AS nulo_preco_minimo,
  COUNTIF(preco_comum IS NULL) AS nulo_preco_comum,
  COUNTIF(preco_maximo IS NULL) AS nulo_preco_maximo,
  COUNTIF(temp_media_3d IS NULL) AS linhas_sem_clima
FROM `pdm-ceasa.silver.ceasa_unificado`
GROUP BY ceasa
ORDER BY ceasa;
