-- Bloco 10: tabela de treino para os três modelos de previsão de preço,
-- construída sobre a Bronze crua, sem nenhum tratamento (sem deduplicar,
-- sem filtrar produto por volume, sem corrigir preço).
--
-- Alvo: preco_comum do mesmo (produto, classe) no pregão mais próximo
-- seguinte a data + 7 dias. Se existir pregão exatamente em D+7, esse é
-- o escolhido; senão, o primeiro pregão seguinte disponível.
-- Linha sem pregão futuro que satisfaça essa condição fica sem alvo e
-- sai da tabela (borda de série, não defeito de dado).
--
-- Features: produto, classe, data e derivados diretos da data (mes,
-- dia_semana). Nenhum preço da própria linha ou de linhas passadas entra
-- como feature: preco_comum/preco_maximo/preco_minimo/preco_kg da bronze
-- não aparecem aqui, exceto como fonte do alvo (que é preço FUTURO,
-- não disponível no momento da previsão).
--
-- Implementação: agrega a série de cada (produto, classe) em um array
-- ordenado por data e busca, por linha, o primeiro elemento do array
-- com data >= data + 7 dias. Evita o produto cartesiano de um self-join
-- direto entre linhas da bronze.
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.baseline.dados_treino` AS
WITH serie AS (
  SELECT
    produto,
    classe,
    ARRAY_AGG(STRUCT(data AS data, preco_comum AS preco_comum) ORDER BY data) AS pregoes
  FROM `pdm-ceasa.bronze.cotacoes`
  GROUP BY produto, classe
),
com_alvo AS (
  SELECT
    b.data,
    b.produto,
    b.classe,
    EXTRACT(MONTH FROM b.data) AS mes,
    EXTRACT(DAYOFWEEK FROM b.data) AS dia_semana,
    (
      SELECT p.preco_comum
      FROM UNNEST(s.pregoes) AS p
      WHERE p.data >= DATE_ADD(b.data, INTERVAL 7 DAY)
      ORDER BY p.data ASC
      LIMIT 1
    ) AS alvo
  FROM `pdm-ceasa.bronze.cotacoes` AS b
  JOIN serie AS s
    ON s.produto = b.produto
   AND s.classe = b.classe
)
SELECT data, produto, classe, mes, dia_semana, alvo
FROM com_alvo
WHERE alvo IS NOT NULL;
