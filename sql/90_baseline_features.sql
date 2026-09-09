-- Baseline: features de defasagem sobre a Bronze crua, sem nenhum tratamento.
-- Não deduplica, não corrige preço, não normaliza categoria, não filtra por volume.
-- Alvo: preco_comum do próximo pregão do mesmo (produto, classe).
-- Features: defasagens t-1 a t-5 do próprio preco_comum, mes e dia da semana
-- derivados de data, produto e classe como categóricas (BQML codifica sozinho).
-- Proibido como feature: preco_maximo, preco_minimo, preco_kg (vazamento, pois
-- são contemporâneos ou derivados do alvo).
--
-- CREATE OR REPLACE: idempotente, reexecutar produz o mesmo resultado.
-- Linha sem as 5 defasagens ou sem alvo (próximo pregão inexistente) é descartada
-- aqui, não corrigida: são bordas de série, não defeito de dado.

CREATE OR REPLACE TABLE `pdm-ceasa.baseline.features` AS
WITH base AS (
  SELECT
    data,
    produto,
    classe,
    mes,
    EXTRACT(DAYOFWEEK FROM data) AS dia_semana,
    LAG(preco_comum, 1) OVER janela AS lag_1,
    LAG(preco_comum, 2) OVER janela AS lag_2,
    LAG(preco_comum, 3) OVER janela AS lag_3,
    LAG(preco_comum, 4) OVER janela AS lag_4,
    LAG(preco_comum, 5) OVER janela AS lag_5,
    LEAD(preco_comum, 1) OVER janela AS alvo
  FROM `pdm-ceasa.bronze.cotacoes`
  WINDOW janela AS (PARTITION BY produto, classe ORDER BY data)
)
SELECT
  data,
  produto,
  classe,
  mes,
  dia_semana,
  lag_1,
  lag_2,
  lag_3,
  lag_4,
  lag_5,
  alvo
FROM base
WHERE alvo IS NOT NULL
  AND lag_1 IS NOT NULL
  AND lag_2 IS NOT NULL
  AND lag_3 IS NOT NULL
  AND lag_4 IS NOT NULL
  AND lag_5 IS NOT NULL;
