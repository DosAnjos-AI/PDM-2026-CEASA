-- Prata CEASA-GO, etapa 05. R7: outliers de preco_kg por IQR x 3.
-- DOCUMENTACAO: este arquivo descreve a logica da etapa e nao executa sozinho.
-- A execucao acontece em ceasa_go_prata.sql, onde esta etapa e uma CTE de
-- mesmo nome. Ao alterar a regra, alterar os dois arquivos.
--
-- Faz: remove preco_kg fora de [Q1 - 3*IQR, Q3 + 3*IQR] por (produto,
-- classe, ano), so quando IQR > 0. PERCENTILE_CONT = interpolacao linear,
-- mesmo metodo do quantile() do pandas.
-- Entra: r6_coerente.
-- Sai: r7_sem_outliers, 296.709 linhas (2.117 removidas).

r7_sem_outliers AS (
  SELECT * EXCEPT (q1, q3)
  FROM (
    SELECT
      *,
      PERCENTILE_CONT(preco_kg, 0.25) OVER (PARTITION BY produto, classe, ano) AS q1,
      PERCENTILE_CONT(preco_kg, 0.75) OVER (PARTITION BY produto, classe, ano) AS q3
    FROM r6_coerente
  )
  WHERE (q3 - q1) <= 0
     OR (preco_kg >= q1 - 3 * (q3 - q1) AND preco_kg <= q3 + 3 * (q3 - q1))
)
