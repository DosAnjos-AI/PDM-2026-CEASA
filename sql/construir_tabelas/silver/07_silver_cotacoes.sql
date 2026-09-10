-- Silver R9 + tabela final: corte de classe e materialização de
-- pdm-ceasa.silver.cotacoes.
-- Faz: mantém apenas classe IN (1, 2); grava a tabela final da camada
-- Silver com as 13 colunas do contrato, na ordem definida.
-- Não faz: nenhuma outra regra -- R1 a R8 já foram aplicadas nos arquivos
-- anteriores. Classes 3 e 4 são raras; 10, 20 e 54 são erro de digitação.
--
-- Esperado: 164 linhas removidas (296.709 -> ~296.545); nenhum produto
-- desaparece com este corte.
--
-- Rebuild total: CREATE OR REPLACE TABLE, sem carga incremental.
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.silver.cotacoes` AS
SELECT
  data, ano, mes, dia, grupo, produto, embalagem, qtd_kg, classe,
  preco_comum, preco_maximo, preco_minimo, preco_kg
FROM `pdm-ceasa.silver.stg_06_depara`
WHERE classe IN (1, 2);
