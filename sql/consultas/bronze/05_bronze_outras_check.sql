-- Conferencia da Bronze das outras sedes: prova de contagem, faixa de datas e
-- nulos por sede, e inspecao visual do alinhamento das colunas.

-- Linhas, datas distintas e faixa de datas por sede
SELECT
  fonte,
  COUNT(*)             AS linhas,
  COUNT(DISTINCT data) AS datas_distintas,
  MIN(data)            AS data_minima,
  MAX(data)            AS data_maxima,
  COUNT(DISTINCT produto) AS produtos_distintos
FROM `bronze.cotacoes_outras`
GROUP BY fonte
ORDER BY fonte;

-- Nulos nas colunas que toda linha deveria ter
SELECT
  fonte,
  COUNTIF(data IS NULL)        AS data_nula,
  COUNTIF(produto IS NULL)     AS produto_nulo,
  COUNTIF(preco_comum IS NULL) AS preco_comum_nulo,
  COUNTIF(arquivo IS NULL)     AS arquivo_nulo
FROM `bronze.cotacoes_outras`
GROUP BY fonte
ORDER BY fonte;

-- Faixa dos precos e violacoes de minimo <= comum <= maximo, por sede
SELECT
  fonte,
  MIN(preco_comum) AS preco_comum_min,
  MAX(preco_comum) AS preco_comum_max,
  COUNTIF(preco_minimo > preco_comum OR preco_comum > preco_maximo) AS ordem_violada
FROM `bronze.cotacoes_outras`
GROUP BY fonte
ORDER BY fonte;

-- 5 linhas, para inspecao visual do alinhamento entre coluna e conteudo
SELECT *
FROM `bronze.cotacoes_outras`
LIMIT 5;
