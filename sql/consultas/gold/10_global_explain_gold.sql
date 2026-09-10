-- ML.GLOBAL_EXPLAIN dos quatro modelos parametricos da Gold (linear e
-- arvore, semanal e mensal) -- peso/importancia de cada feature, material
-- de relatorio e de slide. Os dois ARIMA nao tem ML.GLOBAL_EXPLAIN (nao e
-- um modelo de features tabulares).
-- Nao faz: nao persiste nenhuma tabela, nao retreina nenhum modelo.

SELECT 'regressao_linear' AS modelo, 'semanal' AS granularidade, *
FROM ML.GLOBAL_EXPLAIN(MODEL `pdm-ceasa.gold.modelo_regressao_linear_semanal`)
ORDER BY attribution DESC;

SELECT 'regressao_linear' AS modelo, 'mensal' AS granularidade, *
FROM ML.GLOBAL_EXPLAIN(MODEL `pdm-ceasa.gold.modelo_regressao_linear_mensal`)
ORDER BY attribution DESC;

SELECT 'regressao_arvore' AS modelo, 'semanal' AS granularidade, *
FROM ML.GLOBAL_EXPLAIN(MODEL `pdm-ceasa.gold.modelo_regressao_arvore_semanal`)
ORDER BY attribution DESC;

SELECT 'regressao_arvore' AS modelo, 'mensal' AS granularidade, *
FROM ML.GLOBAL_EXPLAIN(MODEL `pdm-ceasa.gold.modelo_regressao_arvore_mensal`)
ORDER BY attribution DESC;
