-- Confere o resultado de sql/construir_tabelas/metricas/01_comparacao_modelos.sql:
-- existencia e regiao do dataset metricas, contagem de linhas da tabela
-- comparacao_modelos (esperado 6) e o conteudo completo, ordenado por
-- camada e modelo, para colar no relatorio e no slide.
--
-- Nao faz: nao cria, altera nem substitui nenhuma tabela ou modelo.

SELECT schema_name, location
FROM `pdm-ceasa`.INFORMATION_SCHEMA.SCHEMATA
WHERE schema_name = 'metricas';

SELECT COUNT(*) AS total_linhas
FROM `pdm-ceasa.metricas.comparacao_modelos`;

SELECT *
FROM `pdm-ceasa.metricas.comparacao_modelos`
ORDER BY camada, modelo;
