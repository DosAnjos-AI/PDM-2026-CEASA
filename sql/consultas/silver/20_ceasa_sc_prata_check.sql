-- Conferencia de sql/construir_tabelas/silver/11_ceasa_sc_prata.sql.
-- Faz: contagem, produtos, periodo, chaves duplicadas, nulos e faixa dos
-- precos, continuidade da grade diaria por produto e cobertura do JOIN
-- com silver.clima_historico.
-- Nao faz: nao cria nem substitui nenhuma tabela.

-- visao geral (esperado: ceasas_distintas = 1, valor 'SC')
SELECT
  COUNT(*) AS linhas,
  COUNT(DISTINCT produto_canonico) AS produtos_distintos,
  COUNT(DISTINCT ceasa) AS ceasas_distintas,
  ANY_VALUE(ceasa) AS ceasa,
  MIN(data) AS data_min,
  MAX(data) AS data_max
FROM `pdm-ceasa.silver.ceasa_sc`;

-- chaves duplicadas (esperado: 0)
SELECT COUNT(*) AS chaves_duplicadas
FROM (
  SELECT produto_canonico, data, COUNT(*) AS n
  FROM `pdm-ceasa.silver.ceasa_sc`
  GROUP BY produto_canonico, data
  HAVING n > 1
);

-- nulos e faixa dos precos (esperado: nulos = 0 apos interpolacao)
SELECT
  COUNTIF(preco_minimo IS NULL) AS nulo_preco_minimo,
  COUNTIF(preco_comum IS NULL) AS nulo_preco_comum,
  COUNTIF(preco_maximo IS NULL) AS nulo_preco_maximo,
  COUNTIF(preco_minimo <= 0 OR preco_comum <= 0 OR preco_maximo <= 0) AS preco_nao_positivo,
  COUNTIF(preco_minimo > preco_comum OR preco_comum > preco_maximo) AS precos_fora_de_ordem,
  MIN(preco_comum) AS preco_comum_min,
  MAX(preco_comum) AS preco_comum_max
FROM `pdm-ceasa.silver.ceasa_sc`;

-- grade diaria continua por produto (esperado: 0 produtos com buraco)
SELECT COUNT(*) AS produtos_com_buraco
FROM (
  SELECT produto_canonico
  FROM `pdm-ceasa.silver.ceasa_sc`
  GROUP BY produto_canonico
  HAVING COUNT(*) != DATE_DIFF(MAX(data), MIN(data), DAY) + 1
);

-- cobertura do JOIN com clima: linhas sem clima e a faixa de datas delas
-- (esperado: 0, ou apenas datas fora do periodo de silver.clima_historico)
SELECT
  COUNTIF(temp_media_3d IS NULL) AS linhas_sem_clima,
  MIN(IF(temp_media_3d IS NULL, data, NULL)) AS data_min_sem_clima,
  MAX(IF(temp_media_3d IS NULL, data, NULL)) AS data_max_sem_clima
FROM `pdm-ceasa.silver.ceasa_sc`;
