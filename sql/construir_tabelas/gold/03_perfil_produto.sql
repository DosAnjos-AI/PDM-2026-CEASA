-- Gold R3: tabela perfil_produto.
-- Faz: uma linha por (produto, classe), consolidado sobre a serie real da
-- Silver (sem interpolacao): media das 4 colunas de preco, data_inicio
-- (primeira cotacao), data_fim (ultima cotacao), n_meses e n_anos --
-- extensao do intervalo entre data_inicio e data_fim, nao contagem de
-- periodos com dado -- e n_pregoes (total de cotacoes). n_anos deriva
-- diretamente de n_meses (redundantes por construcao, de proposito,
-- decisao do Mestre).
-- Depende de gold.analitica_semanal ja reconstruida (rodar 01_ antes
-- deste script): reusa o corte de faixa longa calculado la (primeira
-- semana real depois do ultimo vao longo do par) e restringe a serie de
-- cada par a partir dele -- por isso data_inicio, n_meses, n_anos, medias
-- e n_pregoes mudam para os pares que sofreram corte de bloco.
-- Nao faz: nao interpola, nao corrige preco_minimo/preco_maximo
-- incoerentes.
--
-- Esperado: 210 linhas (pares produto/classe distintos da Silver). Se
-- divergir, parar e reportar antes de seguir para as tabelas de treino.
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo
-- resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.gold.perfil_produto` AS
WITH cutoff_semanal AS (
  SELECT
    produto,
    classe,
    MIN(data_inicio_semana) AS data_corte
  FROM `pdm-ceasa.gold.analitica_semanal`
  WHERE NOT interpolado
  GROUP BY produto, classe
)
SELECT
  s.produto,
  s.classe,
  ANY_VALUE(s.grupo) AS grupo,
  AVG(s.preco_comum) AS media_preco_comum,
  AVG(s.preco_minimo) AS media_preco_minimo,
  AVG(s.preco_maximo) AS media_preco_maximo,
  AVG(s.preco_kg) AS media_preco_kg,
  MIN(s.data) AS data_inicio,
  MAX(s.data) AS data_fim,
  DATE_DIFF(MAX(s.data), MIN(s.data), MONTH) AS n_meses,
  ROUND(DATE_DIFF(MAX(s.data), MIN(s.data), MONTH) / 12, 1) AS n_anos,
  COUNT(*) AS n_pregoes
FROM `pdm-ceasa.silver.cotacoes` AS s
JOIN cutoff_semanal AS c
  ON c.produto = s.produto AND c.classe = s.classe
WHERE s.data >= c.data_corte
GROUP BY s.produto, s.classe
ORDER BY media_preco_kg DESC;
