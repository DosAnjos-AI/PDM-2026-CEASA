-- Inferencia do modelo silver.modelo_regressao_arvore (BOOSTED_TREE_REGRESSOR,
-- treinado sobre silver.dados_treino --
-- sql/modelo/silver/02_modelo_regressao_arvore.sql). ML.PREDICT apenas le o
-- modelo ja treinado -- nao ha CREATE MODEL nesta consulta, nenhuma tabela
-- e criada ou alterada.
--
-- Vetor, regra de ancora e tecnica de ARRAY_AGG/UNNEST (para evitar
-- subconsulta correlacionada por desigualdade direto na tabela -- erro
-- confirmado em teste) identicos aos de
-- 15_inferencia_regressao_linear.sql (mesma decisao do treino: arvore usa
-- exatamente o mesmo vetor da linear, para a comparacao entre os dois medir
-- o algoritmo, nao o vetor). Ver esse arquivo para o detalhe de cada
-- decisao -- comentario nao duplicado aqui.
--
-- Para trocar produto/classe/data prevista, editar so o bloco DECLARE
-- abaixo -- nenhum outro trecho precisa mudar.

-- ===================== UNICO PONTO DE EDICAO ======================
DECLARE p_produto   STRING DEFAULT 'tomate_saladete';
DECLARE p_classe    INT64  DEFAULT 1;
DECLARE p_data_alvo DATE   DEFAULT '2026-09-04';
-- ====================================================================

DECLARE p_data_base_alvo DATE DEFAULT DATE_SUB(p_data_alvo, INTERVAL 7 DAY);

WITH serie AS (
  SELECT ARRAY_AGG(
    STRUCT(data AS data, preco_comum AS preco_comum, grupo AS grupo, ano AS ano, mes AS mes)
    ORDER BY data
  ) AS pregoes
  FROM `pdm-ceasa.silver.cotacoes`
  WHERE produto = p_produto AND classe = p_classe
),
ancora AS (
  SELECT
    s.pregoes,
    (
      SELECT AS STRUCT p.*
      FROM UNNEST(s.pregoes) AS p
      WHERE p.data <= p_data_base_alvo
      ORDER BY p.data DESC
      LIMIT 1
    ) AS linha_ancora
  FROM serie AS s
),
vetor AS (
  SELECT
    a.linha_ancora.data AS data_base_usada,
    a.linha_ancora.grupo AS grupo,
    a.linha_ancora.ano AS ano,
    a.linha_ancora.mes AS mes,
    EXTRACT(DAYOFWEEK FROM a.linha_ancora.data) AS dia_semana,
    (SELECT p.preco_comum FROM UNNEST(a.pregoes) AS p
     WHERE p.data <= DATE_SUB(a.linha_ancora.data, INTERVAL 7 DAY) ORDER BY p.data DESC LIMIT 1) AS lag_7,
    (SELECT p.preco_comum FROM UNNEST(a.pregoes) AS p
     WHERE p.data <= DATE_SUB(a.linha_ancora.data, INTERVAL 14 DAY) ORDER BY p.data DESC LIMIT 1) AS lag_14,
    (SELECT p.preco_comum FROM UNNEST(a.pregoes) AS p
     WHERE p.data <= DATE_SUB(a.linha_ancora.data, INTERVAL 30 DAY) ORDER BY p.data DESC LIMIT 1) AS lag_30,
    (SELECT p.preco_comum FROM UNNEST(a.pregoes) AS p
     WHERE p.data <= DATE_SUB(a.linha_ancora.data, INTERVAL 365 DAY) ORDER BY p.data DESC LIMIT 1) AS lag_365,
    (SELECT p.preco_comum FROM UNNEST(a.pregoes) AS p
     WHERE p.data <= DATE_SUB(a.linha_ancora.data, INTERVAL 730 DAY) ORDER BY p.data DESC LIMIT 1) AS lag_730
  FROM ancora AS a
)
SELECT
  'silver.modelo_regressao_arvore' AS modelo,
  p_produto AS produto,
  p_classe AS classe,
  p_data_alvo AS data_alvo,
  v.data_base_usada,
  v.lag_7,
  v.lag_14,
  v.lag_30,
  v.lag_365,
  v.lag_730,
  pred.predicted_alvo AS previsao,
  CASE
    WHEN v.data_base_usada IS NULL
      THEN CONCAT('Sem cotacao de ', p_produto, ' classe ', CAST(p_classe AS STRING), ' em ou antes de ', CAST(p_data_base_alvo AS STRING), ' -- previsao nao calculada.')
    WHEN v.lag_7 IS NULL OR v.lag_14 IS NULL OR v.lag_30 IS NULL OR v.lag_365 IS NULL OR v.lag_730 IS NULL
      THEN 'Historico insuficiente para algum lag (produto sem 730 dias de cotacao anterior a data-base) -- previsao nao calculada.'
    ELSE NULL
  END AS observacao
FROM vetor AS v
LEFT JOIN ML.PREDICT(
  MODEL `pdm-ceasa.silver.modelo_regressao_arvore`,
  (
    SELECT
      p_produto AS produto, p_classe AS classe, v.grupo AS grupo, v.ano AS ano, v.mes AS mes, v.dia_semana AS dia_semana,
      v.lag_7 AS lag_7, v.lag_14 AS lag_14, v.lag_30 AS lag_30, v.lag_365 AS lag_365, v.lag_730 AS lag_730
    FROM vetor AS v
    WHERE v.data_base_usada IS NOT NULL
      AND v.lag_7 IS NOT NULL AND v.lag_14 IS NOT NULL AND v.lag_30 IS NOT NULL AND v.lag_365 IS NOT NULL AND v.lag_730 IS NOT NULL
  )
) AS pred
ON TRUE;
