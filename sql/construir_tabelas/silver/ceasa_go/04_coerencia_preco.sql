-- Prata CEASA-GO, etapa 04. R6: coerencia de preco.
-- DOCUMENTACAO: este arquivo descreve a logica da etapa e nao executa sozinho.
-- A execucao acontece em ceasa_go_prata.sql, onde esta etapa e uma CTE de
-- mesmo nome. Ao alterar a regra, alterar os dois arquivos.
--
-- Faz: descarta qtd_kg nulo ou zero, preco_comum zero e preco_kg divergindo
-- mais de 1% de preco_comum / qtd_kg.
-- Entra: r5_densidade.
-- Sai: r6_coerente, 298.826 linhas (1.321 removidas).

r6_coerente AS (
  SELECT *
  FROM r5_densidade
  WHERE NOT (
    qtd_kg IS NULL OR qtd_kg = 0
    OR preco_comum = 0
    OR ABS(preco_kg - SAFE_DIVIDE(preco_comum, qtd_kg))
       / SAFE_DIVIDE(preco_comum, qtd_kg) > 0.01
  )
)
