-- Silver R1+R2: deduplicação, em duas etapas, antes de qualquer outra regra.
-- Faz: remove linhas idênticas em todas as 17 colunas da Bronze (R1); depois
-- remove linhas idênticas em todas as colunas exceto arquivo e layout (R2).
-- Não faz: não descarta coluna, não normaliza texto, não filtra produto,
-- não usa ROW_NUMBER() sobre (produto, classe, data) -- isso colapsaria
-- cotações legitimamente distintas vindas de bases de origem diferentes.
--
-- Esperado: stg_01a_dedup_total = 412.661 linhas (0 removidas pela R1).
-- Esperado: stg_01_deduplicado = 411.488 linhas (1.173 removidas pela R2).
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.silver.stg_01a_dedup_total` AS
SELECT DISTINCT
  data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem,
  qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg,
  layout, arquivo
FROM `pdm-ceasa.bronze.cotacoes`;

CREATE OR REPLACE TABLE `pdm-ceasa.silver.stg_01_deduplicado` AS
SELECT DISTINCT
  data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem,
  qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg
FROM `pdm-ceasa.silver.stg_01a_dedup_total`;
