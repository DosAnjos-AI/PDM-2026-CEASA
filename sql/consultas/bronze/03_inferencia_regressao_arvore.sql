-- Inferencia do modelo baseline.modelo_regressao_arvore (BOOSTED_TREE_REGRESSOR,
-- treinado sobre bronze.cotacoes sem nenhum tratamento --
-- sql/modelo/bronze/03_baseline_treino_arvore.sql). ML.PREDICT apenas le o
-- modelo ja treinado -- nao ha CREATE MODEL nesta consulta, nenhuma tabela
-- e criada ou alterada.
--
-- Vetor identico ao de 02_inferencia_regressao_linear.sql (mesma decisao do
-- treino: arvore usa exatamente o mesmo vetor da linear, produto/classe/
-- mes/dia_semana, para a comparacao entre os dois medir o algoritmo, nao o
-- vetor). Ver esse arquivo para o detalhe de cada decisao -- comentario nao
-- duplicado aqui.
--
-- Para trocar produto/classe/data prevista, editar so o bloco DECLARE
-- abaixo -- nenhum outro trecho precisa mudar.

-- ===================== UNICO PONTO DE EDICAO ======================
DECLARE p_produto   STRING DEFAULT 'tomate_saladete';
DECLARE p_classe    INT64  DEFAULT 1;
DECLARE p_data_alvo DATE   DEFAULT '2026-09-04';
-- ====================================================================

DECLARE p_data_base_alvo DATE DEFAULT DATE_SUB(p_data_alvo, INTERVAL 7 DAY);
DECLARE p_produto_bronze STRING;

SET p_produto_bronze = (
  SELECT ANY_VALUE(produto)
  FROM `pdm-ceasa.bronze.cotacoes`
  WHERE classe = p_classe
    AND REPLACE(
          LOWER(REGEXP_REPLACE(NORMALIZE(REGEXP_REPLACE(TRIM(produto), r' +', ' '), NFD), r'\pM', '')),
          ' ', '_'
        ) = p_produto
);

WITH data_base_encontrada AS (
  SELECT MAX(data) AS data_base_usada
  FROM `pdm-ceasa.bronze.cotacoes`
  WHERE produto = p_produto_bronze
    AND classe = p_classe
    AND data <= p_data_base_alvo
),
vetor AS (
  SELECT
    d.data_base_usada,
    EXTRACT(MONTH FROM d.data_base_usada) AS mes,
    EXTRACT(DAYOFWEEK FROM d.data_base_usada) AS dia_semana
  FROM data_base_encontrada AS d
)
SELECT
  'baseline.modelo_regressao_arvore' AS modelo,
  p_produto AS produto,
  p_classe AS classe,
  p_data_alvo AS data_alvo,
  v.data_base_usada,
  v.mes,
  v.dia_semana,
  pred.predicted_alvo AS previsao,
  CASE
    WHEN p_produto_bronze IS NULL
      THEN CONCAT('Produto "', p_produto, '" classe ', CAST(p_classe AS STRING), ' nao encontrado na bronze apos normalizacao.')
    WHEN v.data_base_usada IS NULL
      THEN CONCAT('Sem cotacao de ', p_produto, ' classe ', CAST(p_classe AS STRING), ' em ou antes de ', CAST(p_data_base_alvo AS STRING), ' -- previsao nao calculada.')
    ELSE NULL
  END AS observacao
FROM vetor AS v
LEFT JOIN ML.PREDICT(
  MODEL `pdm-ceasa.baseline.modelo_regressao_arvore`,
  (
    SELECT
      p_produto_bronze AS produto,
      p_classe AS classe,
      v.mes AS mes,
      v.dia_semana AS dia_semana
    FROM vetor AS v
    WHERE v.data_base_usada IS NOT NULL
  )
) AS pred
ON TRUE;
