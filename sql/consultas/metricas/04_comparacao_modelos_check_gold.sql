-- Confere o resultado de
-- sql/construir_tabelas/metricas/02_amplia_comparacao_modelos_gold.sql +
-- scripts/metricas_demo_gold.py: contagem de linhas (esperado 12) e o
-- conteudo completo, ordenado por camada, granularidade e modelo, para
-- colar no relatorio e no slide.
--
-- Nao faz: nao cria, altera nem substitui nenhuma tabela ou modelo.

SELECT COUNT(*) AS total_linhas
FROM `pdm-ceasa.metricas.comparacao_modelos`;

SELECT *
FROM `pdm-ceasa.metricas.comparacao_modelos`
ORDER BY camada, granularidade, modelo;
