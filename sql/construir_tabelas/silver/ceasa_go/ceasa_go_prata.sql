-- Prata CEASA-GO: script unico que executa a cadeia R1 -> R8 + escopo e grava
-- pdm-ceasa.silver.ceasa_go_prata. Nenhuma tabela intermediaria e criada:
-- cada etapa e uma CTE nomeada. Os arquivos 01_ a 07_ desta pasta documentam
-- a logica de cada etapa; este e o unico que executa.
--
-- Entra: pdm-ceasa.bronze.ceasa_go (412.661 linhas, 17 colunas). Somente leitura.
-- Sai:   pdm-ceasa.silver.ceasa_go_prata, 16 colunas:
--        data, ano, mes, dia, grupo, produto (canonico), produto_bronze
--        (nome cru da bronze), embalagem, qtd_kg, classe, preco_comum,
--        preco_maximo, preco_minimo, preco_kg, layout, arquivo.
--
-- Checkpoint de equivalencia com o notebook ceasa_go_prata.ipynb: CTE prata
-- com 66.057 linhas, 26 produtos, classe = '1'. E checkpoint, nao destino: o
-- script sera reescrito a cada rodada de limpeza.
-- Saida atual (apos corte_2017 e p2_inversao): 44.963 linhas, 26 produtos,
-- 2017-01-02+; lapidacao em curso, ver log em docs/auditoria-precos-ceasa-go.md.
--
-- CREATE OR REPLACE TABLE: idempotente, reexecutar produz o mesmo resultado.

CREATE OR REPLACE TABLE `pdm-ceasa.silver.ceasa_go_prata` AS
WITH

-- R1: deduplicacao ignorando arquivo e layout (equivale ao drop_duplicates
-- com subset sem essas duas colunas). layout e arquivo sao preservados para
-- auditoria: quando a deduplicacao colapsa linhas de origens diferentes, os
-- valores distintos ficam concatenados com ','.
-- Esperado ao fim: 411.488 linhas (1.173 removidas).
r1_dedup AS (
  SELECT
    data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem,
    qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg,
    STRING_AGG(DISTINCT layout, ',' ORDER BY layout) AS layout,
    STRING_AGG(DISTINCT arquivo, ',' ORDER BY arquivo) AS arquivo
  FROM `pdm-ceasa.bronze.ceasa_go`
  GROUP BY
    data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem,
    qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg
),

-- R2 + R3 + R4: descarta categoria e codigo; normaliza grupo, produto e
-- embalagem (trim, colapsa espacos, NFD, remove marcas, minuscula, espaco
-- vira '_'); converte qtd_kg e os quatro precos para FLOAT64. O nome cru de
-- produto segue em produto_bronze.
-- Esperado ao fim: 411.488 linhas, 372 produtos.
r3_normalizado AS (
  SELECT
    data, ano, mes, dia,
    REPLACE(LOWER(REGEXP_REPLACE(
      NORMALIZE(REGEXP_REPLACE(TRIM(grupo), r' +', ' '), NFD), r'\pM', '')), ' ', '_') AS grupo,
    REPLACE(LOWER(REGEXP_REPLACE(
      NORMALIZE(REGEXP_REPLACE(TRIM(produto), r' +', ' '), NFD), r'\pM', '')), ' ', '_') AS produto,
    produto AS produto_bronze,
    REPLACE(LOWER(REGEXP_REPLACE(
      NORMALIZE(REGEXP_REPLACE(TRIM(embalagem), r' +', ' '), NFD), r'\pM', '')), ' ', '_') AS embalagem,
    CAST(qtd_kg AS FLOAT64) AS qtd_kg,
    classe,
    CAST(preco_comum AS FLOAT64) AS preco_comum,
    CAST(preco_maximo AS FLOAT64) AS preco_maximo,
    CAST(preco_minimo AS FLOAT64) AS preco_minimo,
    CAST(preco_kg AS FLOAT64) AS preco_kg,
    layout, arquivo
  FROM r1_dedup
),

-- R5a: produtos ativos (cotados em 2026-06-01+), com inicio antes de
-- 2023-01-01 e densidade >= 80% na janela 2017+.
-- Densidade = pregoes cotados / pregoes da base no intervalo do produto.
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

-- R5b: dos sobreviventes de R5a, densidade >= 92% na serie completa.
-- Esperado ao fim: 141 produtos.
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

-- R5: aplica a lista de densidade. No-op para os 26 do escopo (todos estao
-- entre os 141), mantido por fidelidade ao notebook.
-- Esperado ao fim: 300.147 linhas, 141 produtos.
r5_densidade AS (
  SELECT *
  FROM r3_normalizado
  WHERE produto IN (SELECT produto FROM r5b_lista)
),

-- R6: coerencia de preco. Descarta qtd_kg nulo ou zero, preco_comum zero e
-- preco_kg divergindo mais de 1% de preco_comum / qtd_kg.
-- Esperado ao fim: 298.826 linhas (1.321 removidas).
r6_coerente AS (
  SELECT *
  FROM r5_densidade
  WHERE NOT (
    qtd_kg IS NULL OR qtd_kg = 0
    OR preco_comum = 0
    OR ABS(preco_kg - SAFE_DIVIDE(preco_comum, qtd_kg))
       / SAFE_DIVIDE(preco_comum, qtd_kg) > 0.01
  )
),

-- R7: remove outlier de preco_kg fora de [Q1 - 3*IQR, Q3 + 3*IQR] por
-- (produto, classe, ano), so quando IQR > 0. PERCENTILE_CONT usa
-- interpolacao linear, o mesmo metodo do quantile() padrao do pandas.
-- Esperado ao fim: 296.709 linhas (2.117 removidas).
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
),

-- R8: de-para dos 8 erros de digitacao; destino e a grafia de maior
-- contagem, nao a gramaticalmente correta (por isso a gala correta vira a
-- grafia com erro).
-- Esperado ao fim: 296.709 linhas (nenhuma removida).
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
),

-- Escopo: 26 produtos, classe = '1', renomeados para o nome canonico. A chave
-- e o nome apos R3 e R8.
-- Esperado ao fim: 66.057 linhas, 26 produtos, classe distinta apenas '1'.
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

SELECT * FROM p2_inversao;
