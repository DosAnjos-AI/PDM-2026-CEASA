-- Prata CEASA-GO, etapa 01. R1: deduplicacao ignorando arquivo e layout.
-- DOCUMENTACAO: este arquivo descreve a logica da etapa e nao executa sozinho.
-- A execucao acontece em ceasa_go_prata.sql, onde esta etapa e uma CTE de
-- mesmo nome. Ao alterar a regra, alterar os dois arquivos.
--
-- Faz: agrupa pelas 15 colunas restantes (equivale a SELECT DISTINCT sem
-- arquivo/layout); preserva layout e arquivo concatenando os valores
-- distintos com ',' quando linhas de origens diferentes colapsam.
-- Entra: bronze.ceasa_go, 412.661 linhas, 17 colunas.
-- Sai: r1_dedup, 411.488 linhas (1.173 removidas), 372 produtos crus.
-- 130 linhas da prata final carregam mais de um arquivo.

r1_dedup AS (
  SELECT
    data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem,
    qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg,
    STRING_AGG(DISTINCT layout, ',' ORDER BY layout) AS layout,
    STRING_AGG(DISTINCT arquivo, ',' ORDER BY arquivo) AS arquivo
  FROM `pdm-ceasa.bronze.ceasa_go`
  GROUP BY
    data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem,
    qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg
)
