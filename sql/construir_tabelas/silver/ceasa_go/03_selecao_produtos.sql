-- Prata CEASA-GO, etapa 03. R5: filtro de densidade em duas janelas.
-- DOCUMENTACAO: este arquivo descreve a logica da etapa e nao executa sozinho.
-- A execucao acontece em ceasa_go_prata.sql, onde esta etapa e uma CTE de
-- mesmo nome. Ao alterar a regra, alterar os dois arquivos.
--
-- Faz: R5a mantem produtos ativos (2026-06-01+), com inicio < 2023-01-01 e
-- densidade >= 80% na janela 2017+; R5b mantem, desses, densidade >= 92%
-- na serie completa. No-op para os 26 do escopo (todos entre os 141).
-- Entra: r3_normalizado.
-- Sai: r5a_lista 184 produtos; r5b_lista 141 produtos;
-- r5_densidade 300.147 linhas.

r5a_lista AS (
  SELECT p.produto
  FROM (
    SELECT produto, MIN(data) AS primeira, MAX(data) AS ultima,
           COUNT(DISTINCT data) AS cotados
    FROM r3_normalizado
    WHERE data >= '2017-01-01'
      AND produto IN (
        SELECT produto FROM r3_normalizado
        GROUP BY produto
        HAVING MAX(data) >= '2026-06-01' AND MIN(data) < '2023-01-01'
      )
    GROUP BY produto
  ) AS p
  WHERE p.cotados / (
    SELECT COUNT(DISTINCT c.data) FROM r3_normalizado AS c
    WHERE c.data >= '2017-01-01' AND c.data BETWEEN p.primeira AND p.ultima
  ) >= 0.80
),

r5b_lista AS (
  SELECT p.produto
  FROM (
    SELECT produto, MIN(data) AS primeira, MAX(data) AS ultima,
           COUNT(DISTINCT data) AS cotados
    FROM r3_normalizado
    WHERE produto IN (SELECT produto FROM r5a_lista)
    GROUP BY produto
  ) AS p
  WHERE p.cotados / (
    SELECT COUNT(DISTINCT c.data) FROM r3_normalizado AS c
    WHERE c.data BETWEEN p.primeira AND p.ultima
  ) >= 0.92
),

r5_densidade AS (
  SELECT *
  FROM r3_normalizado
  WHERE produto IN (SELECT produto FROM r5b_lista)
)
