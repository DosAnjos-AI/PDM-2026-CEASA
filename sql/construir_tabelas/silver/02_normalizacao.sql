-- Silver R3+R4: descarte de colunas e normalização de texto/tipos.
-- Faz: descarta categoria e codigo (layout e arquivo já saíram na etapa 01);
-- normaliza grupo, produto e embalagem na ordem exata (trim, colapsar
-- espaços, remover acentos, minúscula, espaço vira "_"); converte qtd_kg e
-- os quatro campos de preço para FLOAT64.
-- Não faz: não filtra produto, não corrige preço, não deduplica (isso já
-- aconteceu na etapa 01). ano, mes, dia, classe e data já chegam tipados
-- corretamente da Bronze (INT64/DATE) e não precisam de CAST.
--
-- Esperado: mesma contagem de linhas de stg_01_deduplicado (411.488),
-- nenhum nulo novo introduzido pelo CAST. Distintos após normalização:
-- grupo = 8, produto = 372, embalagem = 19.
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.silver.stg_02_normalizado` AS
SELECT
  data,
  ano,
  mes,
  dia,
  REPLACE(
    LOWER(
      REGEXP_REPLACE(
        NORMALIZE(REGEXP_REPLACE(TRIM(grupo), r' +', ' '), NFD),
        r'\pM', ''
      )
    ),
    ' ', '_'
  ) AS grupo,
  REPLACE(
    LOWER(
      REGEXP_REPLACE(
        NORMALIZE(REGEXP_REPLACE(TRIM(produto), r' +', ' '), NFD),
        r'\pM', ''
      )
    ),
    ' ', '_'
  ) AS produto,
  REPLACE(
    LOWER(
      REGEXP_REPLACE(
        NORMALIZE(REGEXP_REPLACE(TRIM(embalagem), r' +', ' '), NFD),
        r'\pM', ''
      )
    ),
    ' ', '_'
  ) AS embalagem,
  CAST(qtd_kg AS FLOAT64) AS qtd_kg,
  classe,
  CAST(preco_comum AS FLOAT64) AS preco_comum,
  CAST(preco_maximo AS FLOAT64) AS preco_maximo,
  CAST(preco_minimo AS FLOAT64) AS preco_minimo,
  CAST(preco_kg AS FLOAT64) AS preco_kg
FROM `pdm-ceasa.silver.stg_01_deduplicado`;
