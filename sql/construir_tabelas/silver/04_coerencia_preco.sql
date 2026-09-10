-- Silver R6: coerência de preco_kg com preco_comum/qtd_kg.
-- Faz: descarta linha com qtd_kg nulo ou zero, preco_comum zero, ou onde
-- preco_kg diverge de preco_comum/qtd_kg em mais de 1%.
-- Não faz: não corrige nem imputa nenhum dos três campos -- onde não fecha,
-- descartar é mais seguro que adivinhar qual das três colunas está errada.
-- SAFE_DIVIDE evita erro de divisão por zero nas linhas já descartadas pela
-- primeira condição (qtd_kg nulo/zero).
--
-- Esperado: 16 linhas por incoerência + 1.305 por base de cálculo inválida
-- (qtd_kg nulo/zero ou preco_comum zero) removidas.
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.silver.stg_04_preco_coerente` AS
SELECT *
FROM `pdm-ceasa.silver.stg_03_selecionado`
WHERE NOT (
  qtd_kg IS NULL OR qtd_kg = 0
  OR preco_comum = 0
  OR ABS(preco_kg - SAFE_DIVIDE(preco_comum, qtd_kg)) / SAFE_DIVIDE(preco_comum, qtd_kg) > 0.01
);
