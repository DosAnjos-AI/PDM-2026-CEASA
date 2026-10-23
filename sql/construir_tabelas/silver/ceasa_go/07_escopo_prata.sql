-- Prata CEASA-GO, etapa 07. Escopo final: 26 produtos, classe 1, nome canonico,
-- corte temporal em 2017-01-01 e etapas de lapidacao (p2_*).
-- DOCUMENTACAO: este arquivo descreve a logica da etapa e nao executa sozinho.
-- A execucao acontece em ceasa_go_prata.sql, onde esta etapa e uma CTE de
-- mesmo nome. Ao alterar a regra, alterar os dois arquivos.
--
-- Faz: junta com o de-para dos 26 (chave = nome apos R3 e R8), filtra
-- classe = '1', renomeia para o canonico e mantem produto_bronze, layout e
-- arquivo para auditoria; por ultimo, mantem apenas data >= 2017-01-01.
-- Entra: r8_de_para.
-- Sai: prata, 66.057 linhas, 26 produtos, classe so '1' (checkpoint de
-- equivalencia com o notebook); corte_2017, 44.963 linhas, 26 produtos;
-- p2_inversao, 44.963 linhas, 31 linhas com min/max corrigidos.

prata AS (
  SELECT
    r.data, r.ano, r.mes, r.dia, r.grupo,
    e.canonico AS produto,
    r.produto_bronze,
    r.embalagem, r.qtd_kg, r.classe,
    r.preco_comum, r.preco_maximo, r.preco_minimo, r.preco_kg,
    r.layout, r.arquivo
  FROM r8_de_para AS r
  JOIN UNNEST([
    STRUCT('abobora_verde_italiana' AS literal, 'abobrinha_italiana' AS canonico),
    STRUCT('banana_maca', 'banana_maca'),
    STRUCT('batata_comum_diversas', 'batata_inglesa'),
    STRUCT('batata_lisa_(achati-binj)', 'batata_lisa'),
    STRUCT('berinjela', 'berinjela'),
    STRUCT('beterraba', 'beterraba'),
    STRUCT('cenoura', 'cenoura'),
    STRUCT('chuchu', 'chuchu'),
    STRUCT('coco_seco', 'coco_seco'),
    STRUCT('coco_verde', 'coco_verde'),
    STRUCT('laranja_lima', 'laranja_lima'),
    STRUCT('laranja_pera_rio', 'laranja_pera'),
    STRUCT('limao_tahiti_(sp)', 'limao_taiti'),
    STRUCT('maca_nacional_fugi_(cart)_t150', 'maca_fuji'),
    STRUCT('maca_naiconal_gala_(cart.)_t150', 'maca_gala'),
    STRUCT('mamao_formosa', 'mamao_formosa'),
    STRUCT('maracuja_azedo', 'maracuja_azedo'),
    STRUCT('melancia', 'melancia'),
    STRUCT('milho_verde', 'milho_verde'),
    STRUCT('morango', 'morango'),
    STRUCT('pimentao', 'pimentao_verde'),
    STRUCT('quiabo', 'quiabo'),
    STRUCT('repolho', 'repolho_verde'),
    STRUCT('repolho_roxo', 'repolho_roxo'),
    STRUCT('tomate_longa_vida', 'tomate_longa_vida'),
    STRUCT('uva_italia', 'uva_italia')
  ]) AS e
    ON e.literal = r.produto
  WHERE r.classe = '1'
),

-- Corte temporal: mantem data >= 2017-01-01. Remove o trecho xlsx ate
-- 2016-07-21, onde preco_minimo e copia do maximo em 100% das linhas, e o
-- restante de 2016 junto (decisao do Mestre, 2026-10-16).
-- Esperado ao fim: 44.963 linhas (21.094 removidas), 26 produtos.
corte_2017 AS (
  SELECT *
  FROM prata
  WHERE data >= '2017-01-01'
),

-- Lapidacao, problema 2: preco_minimo > preco_maximo (34 linhas).
-- Classifica a inversao em 4 padroes (decisao do Mestre, 2026-10-17):
--   P1 escala no minimo (min/max >= 3, comum <= max): minimo = media dos
--      minimos do pregao valido anterior e posterior; maximo preservado
--   P2 escala no maximo (min/max >= 3, comum > max): maximo = media dos
--      maximos vizinhos; minimo preservado
--   P3 troca simples (comum cabe com min e max trocados): troca as colunas
--   P4 comum acima dos dois: minimo e maximo = medias dos vizinhos
-- Vizinho valido: pregao do mesmo produto com min <= comum <= max. Na borda,
-- usa o unico vizinho disponivel. preco_comum e preco_kg nao sao tocados.
-- Guarda: so aplica se min <= comum <= max apos a correcao; as linhas
-- rejeitadas ficam como estao. Media arredondada a 3 casas (remove residuo de
-- ponto flutuante; media de valores com 2 casas tem no maximo 3).
-- Esperado ao fim: 44.963 linhas; 31 corrigidas, 3 rejeitadas pela guarda
-- (cenoura 2017-05-22, quiabo 2018-04-24, quiabo 2023-06-08); min > max = 3.
p2_base AS (
  SELECT *,
    (preco_minimo <= preco_comum AND preco_comum <= preco_maximo) AS valido,
    CASE
      WHEN NOT (preco_minimo > preco_maximo) THEN NULL
      WHEN preco_minimo / preco_maximo >= 3 AND preco_comum <= preco_maximo THEN 'P1'
      WHEN preco_minimo / preco_maximo >= 3 THEN 'P2'
      WHEN preco_comum BETWEEN preco_maximo AND preco_minimo THEN 'P3'
      ELSE 'P4'
    END AS padrao
  FROM corte_2017
),

p2_vizinhos AS (
  SELECT *,
    LAST_VALUE(IF(valido, preco_minimo, NULL) IGNORE NULLS) OVER ant AS ant_min,
    LAST_VALUE(IF(valido, preco_maximo, NULL) IGNORE NULLS) OVER ant AS ant_max,
    FIRST_VALUE(IF(valido, preco_minimo, NULL) IGNORE NULLS) OVER pos AS pos_min,
    FIRST_VALUE(IF(valido, preco_maximo, NULL) IGNORE NULLS) OVER pos AS pos_max
  FROM p2_base
  WINDOW
    ant AS (PARTITION BY produto ORDER BY data ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
    pos AS (PARTITION BY produto ORDER BY data ROWS BETWEEN 1 FOLLOWING AND UNBOUNDED FOLLOWING)
),

p2_calculo AS (
  SELECT *,
    ROUND(CASE padrao
      WHEN 'P1' THEN COALESCE((ant_min + pos_min) / 2, ant_min, pos_min)
      WHEN 'P3' THEN preco_maximo
      WHEN 'P4' THEN COALESCE((ant_min + pos_min) / 2, ant_min, pos_min)
      ELSE preco_minimo
    END, 3) AS novo_min,
    ROUND(CASE padrao
      WHEN 'P2' THEN COALESCE((ant_max + pos_max) / 2, ant_max, pos_max)
      WHEN 'P3' THEN preco_minimo
      WHEN 'P4' THEN COALESCE((ant_max + pos_max) / 2, ant_max, pos_max)
      ELSE preco_maximo
    END, 3) AS novo_max
  FROM p2_vizinhos
),

p2_inversao AS (
  SELECT * EXCEPT (valido, padrao, ant_min, ant_max, pos_min, pos_max, novo_min, novo_max)
    REPLACE (
      IF(padrao IS NOT NULL AND novo_min <= preco_comum AND preco_comum <= novo_max,
         novo_min, preco_minimo) AS preco_minimo,
      IF(padrao IS NOT NULL AND novo_min <= preco_comum AND preco_comum <= novo_max,
         novo_max, preco_maximo) AS preco_maximo
    )
  FROM p2_calculo
)
