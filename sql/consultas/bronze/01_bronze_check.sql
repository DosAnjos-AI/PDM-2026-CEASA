-- Conferência da camada Bronze: prova de contagem, faixa de datas,
-- distinção de produtos/classe e inspeção visual do alinhamento das colunas.

-- Contagem total de linhas
SELECT COUNT(*) AS total_linhas
FROM `pdm-ceasa.bronze.cotacoes`;

-- Data mínima e máxima
SELECT MIN(data) AS data_minima, MAX(data) AS data_maxima
FROM `pdm-ceasa.bronze.cotacoes`;

-- Contagem de produtos distintos
SELECT COUNT(DISTINCT produto) AS produtos_distintos
FROM `pdm-ceasa.bronze.cotacoes`;

-- Contagem de valores distintos de classe
SELECT COUNT(DISTINCT classe) AS classes_distintas
FROM `pdm-ceasa.bronze.cotacoes`;

-- 5 primeiras linhas, para inspeção visual do alinhamento entre coluna e conteúdo
SELECT *
FROM `pdm-ceasa.bronze.cotacoes`
LIMIT 5;
