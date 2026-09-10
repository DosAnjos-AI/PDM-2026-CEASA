-- Silver R8: de-para de erros de digitação em nomes de produto.
-- Faz: unifica os 8 pares de grafia via tabela de mapeamento explícita. O
-- destino é sempre o nome de maior contagem na base -- a Silver preserva o
-- nome canônico do dado, não o nome gramaticalmente correto.
-- Não faz: não altera nenhum outro produto; esta é a única regra com
-- exceção nomeada a produto individual, por natureza (mapeamento explícito).
--
-- Esperado: 0 linhas removidas, 141 produtos mantidos, sem conflito de
-- chave (produto, classe, data) gerado pela unificação.
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.silver.stg_06_depara` AS
WITH depara AS (
  SELECT * FROM UNNEST([
    STRUCT('pimenta_dedo-de-_moca' AS origem, 'pimenta_dedo-de-moca' AS destino),
    STRUCT('ameixa_amaricana', 'ameixa_americana'),
    STRUCT('banana_marmela', 'banana_marmel0'),
    STRUCT('pepino_colonhao', 'pepino_coloniao'),
    STRUCT('couve_flor', 'couve-flor'),
    STRUCT('porvilho', 'polvilho'),
    STRUCT('uva_niagara_cx_cx_5,500_kg', 'uva_niagara_cx_5,500_kg'),
    STRUCT('maca_nacional_gala_(cart.)_t150', 'maca_naiconal_gala_(cart.)_t150')
  ])
)
SELECT
  s.data, s.ano, s.mes, s.dia, s.grupo,
  COALESCE(d.destino, s.produto) AS produto,
  s.embalagem, s.qtd_kg, s.classe, s.preco_comum, s.preco_maximo,
  s.preco_minimo, s.preco_kg
FROM `pdm-ceasa.silver.stg_05_sem_outliers` AS s
LEFT JOIN depara AS d ON d.origem = s.produto;
