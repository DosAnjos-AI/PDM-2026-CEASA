-- Prata CEASA-GO, etapa 06. R8: de-para dos 8 erros de digitacao em produto.
-- DOCUMENTACAO: este arquivo descreve a logica da etapa e nao executa sozinho.
-- A execucao acontece em ceasa_go_prata.sql, onde esta etapa e uma CTE de
-- mesmo nome. Ao alterar a regra, alterar os dois arquivos.
--
-- Faz: unifica grafias para a de maior contagem. Em GO e no-op para o
-- escopo: a grafia 'MACA NACIONAL GALA (CART.) T150' nao existe na bronze.
-- Entra: r7_sem_outliers.
-- Sai: r8_de_para, 296.709 linhas (nenhuma removida).

r8_de_para AS (
  SELECT r.* REPLACE (COALESCE(d.destino, r.produto) AS produto)
  FROM r7_sem_outliers AS r
  LEFT JOIN UNNEST([
    STRUCT('pimenta_dedo-de-_moca' AS origem, 'pimenta_dedo-de-moca' AS destino),
    STRUCT('ameixa_amaricana', 'ameixa_americana'),
    STRUCT('banana_marmela', 'banana_marmel0'),
    STRUCT('pepino_colonhao', 'pepino_coloniao'),
    STRUCT('couve_flor', 'couve-flor'),
    STRUCT('porvilho', 'polvilho'),
    STRUCT('uva_niagara_cx_cx_5,500_kg', 'uva_niagara_cx_5,500_kg'),
    STRUCT('maca_nacional_gala_(cart.)_t150', 'maca_naiconal_gala_(cart.)_t150')
  ]) AS d
    ON d.origem = r.produto
)
