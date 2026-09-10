-- Silver R7: remoção de outlier de preco_kg, por (produto, classe, ano).
-- Faz: calcula Q1/Q3/IQR de preco_kg dentro de cada grupo (produto, classe,
-- ano) e remove linha fora de [Q1 - 3*IQR, Q3 + 3*IQR], só quando IQR > 0.
-- Não faz: não aplica corte de outlier quando IQR = 0 (grupo sem variação);
-- não agrupa sem ano -- sem ele, a variação de patamar de preço ao longo de
-- 16 anos seria marcada como outlier (verificado empiricamente). Paliativo
-- consciente, registrado para refinamento na T2.
--
-- Esperado: 2.117 linhas removidas (298.826 -> 296.709).
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.silver.stg_05_sem_outliers` AS
WITH com_quartis AS (
  SELECT
    *,
    PERCENTILE_CONT(preco_kg, 0.25) OVER (PARTITION BY produto, classe, ano) AS q1,
    PERCENTILE_CONT(preco_kg, 0.75) OVER (PARTITION BY produto, classe, ano) AS q3
  FROM `pdm-ceasa.silver.stg_04_preco_coerente`
),
com_iqr AS (
  SELECT *, (q3 - q1) AS iqr
  FROM com_quartis
)
SELECT
  data, ano, mes, dia, grupo, produto, embalagem, qtd_kg, classe,
  preco_comum, preco_maximo, preco_minimo, preco_kg
FROM com_iqr
WHERE iqr <= 0
   OR (preco_kg >= q1 - 3 * iqr AND preco_kg <= q3 + 3 * iqr);
