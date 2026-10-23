-- Prata CEASA-GO, etapa 02. R2 + R3 + R4: descarte de colunas, normalizacao de texto e tipos.
-- DOCUMENTACAO: este arquivo descreve a logica da etapa e nao executa sozinho.
-- A execucao acontece em ceasa_go_prata.sql, onde esta etapa e uma CTE de
-- mesmo nome. Ao alterar a regra, alterar os dois arquivos.
--
-- Faz: descarta categoria e codigo; normaliza grupo, produto e embalagem
-- (TRIM, colapsa espacos, NFD, remove marcas, LOWER, espaco vira '_');
-- CAST para FLOAT64 de qtd_kg e dos quatro precos. Guarda o nome cru em
-- produto_bronze. classe permanece STRING, como na bronze.
-- Entra: r1_dedup.
-- Sai: r3_normalizado, 411.488 linhas, 372 produtos normalizados.

r3_normalizado AS (
  SELECT
    data, ano, mes, dia,
    REPLACE(LOWER(REGEXP_REPLACE(
      NORMALIZE(REGEXP_REPLACE(TRIM(grupo), r' +', ' '), NFD), r'\pM', '')), ' ', '_') AS grupo,
    REPLACE(LOWER(REGEXP_REPLACE(
      NORMALIZE(REGEXP_REPLACE(TRIM(produto), r' +', ' '), NFD), r'\pM', '')), ' ', '_') AS produto,
    produto AS produto_bronze,
    REPLACE(LOWER(REGEXP_REPLACE(
      NORMALIZE(REGEXP_REPLACE(TRIM(embalagem), r' +', ' '), NFD), r'\pM', '')), ' ', '_') AS embalagem,
    CAST(qtd_kg AS FLOAT64) AS qtd_kg,
    classe,
    CAST(preco_comum AS FLOAT64) AS preco_comum,
    CAST(preco_maximo AS FLOAT64) AS preco_maximo,
    CAST(preco_minimo AS FLOAT64) AS preco_minimo,
    CAST(preco_kg AS FLOAT64) AS preco_kg,
    layout, arquivo
  FROM r1_dedup
)
