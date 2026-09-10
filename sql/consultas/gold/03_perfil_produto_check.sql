-- Conferencia de sql/construir_tabelas/gold/03_perfil_produto.sql.
-- Faz: confere COUNT(*) = 210, data minima/maxima da serie, amostra dos
-- maiores intervalos (n_meses/n_anos), e lista os pares que sofreram
-- corte de bloco (data_inicio pos-corte diferente do data_inicio original
-- direto da Silver), com quanto de serie cada um perdeu.
-- Nao faz: nao cria nem substitui nenhuma tabela.

SELECT COUNT(*) AS linhas_perfil_produto
FROM `pdm-ceasa.gold.perfil_produto`;

SELECT MIN(data_inicio) AS data_inicio_min, MAX(data_fim) AS data_fim_max
FROM `pdm-ceasa.gold.perfil_produto`;

SELECT produto, classe, data_inicio, data_fim, n_meses, n_anos, n_pregoes
FROM `pdm-ceasa.gold.perfil_produto`
ORDER BY n_meses DESC
LIMIT 5;

-- consistencia: par presente na Silver mas ausente do perfil_produto
SELECT COUNT(*) AS pares_ausentes
FROM (
  SELECT DISTINCT produto, classe FROM `pdm-ceasa.silver.cotacoes`
  EXCEPT DISTINCT
  SELECT DISTINCT produto, classe FROM `pdm-ceasa.gold.perfil_produto`
);

-- pares que sofreram corte de bloco -- compara data_inicio pos-corte com
-- o data_inicio original direto da Silver (sem corte); vazio = nenhum par
-- teve vao longo
WITH original AS (
  SELECT
    produto, classe,
    MIN(data) AS data_inicio_original,
    COUNT(*) AS n_pregoes_original
  FROM `pdm-ceasa.silver.cotacoes`
  GROUP BY produto, classe
)
SELECT
  p.produto,
  p.classe,
  o.data_inicio_original,
  p.data_inicio AS data_inicio_pos_corte,
  DATE_DIFF(p.data_inicio, o.data_inicio_original, DAY) AS dias_perdidos,
  o.n_pregoes_original - p.n_pregoes AS pregoes_perdidos
FROM `pdm-ceasa.gold.perfil_produto` AS p
JOIN original AS o
  ON o.produto = p.produto AND o.classe = p.classe
WHERE p.data_inicio != o.data_inicio_original
ORDER BY dias_perdidos DESC;
