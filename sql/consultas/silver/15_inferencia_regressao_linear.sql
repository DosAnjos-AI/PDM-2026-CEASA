-- Inferencia do modelo silver.modelo_regressao_linear (LINEAR_REG elastic
-- net, treinado sobre silver.dados_treino --
-- sql/modelo/silver/01_modelo_regressao_linear.sql). ML.PREDICT apenas le o
-- modelo ja treinado -- nao ha CREATE MODEL nesta consulta, nenhuma tabela
-- e criada ou alterada.
--
-- Fonte do vetor: pdm-ceasa.silver.cotacoes -- NAO silver.dados_treino, de
-- proposito. dados_treino so guarda linha com alvo conhecido (WHERE alvo IS
-- NOT NULL em sql/construir_tabelas/silver/08_dados_treino.sql), o que
-- descarta justamente as datas recentes sem D+7 futuro ainda observado --
-- exatamente as datas que esta consulta precisa prever. Por isso o vetor e
-- remontado aqui direto da cotacoes crua da Silver.
--
-- Vetor: produto, classe, grupo, ano, mes, dia_semana, lag_7, lag_14,
-- lag_30, lag_365, lag_730 -- identico ao treino.
--
-- Regra de data-base e ancora: data-base = p_data_alvo - 7 dias (passo do
-- modelo). Se nao houver pregao exatamente nessa data, usa-se a ultima
-- cotacao real anterior ou igual a ela -- mesma regra das tabelas de treino
-- (cada linha de dados_treino vem de uma data com pregao real). Essa data
-- efetivamente encontrada (data_base_usada) e a ANCORA: grupo/ano/mes/
-- dia_semana vem dela, e cada lag_N e a ultima cotacao com
-- data <= data_base_usada - N dias -- nunca a partir de p_data_alvo nem do
-- calendario cru da data-base pedida.
--
-- Implementacao: agrega a serie inteira do (produto, classe) pedido em um
-- ARRAY (uma unica leitura de silver.cotacoes) e usa UNNEST desse array,
-- nunca uma nova consulta a tabela, dentro de cada subconsulta escalar --
-- mesma tecnica de sql/construir_tabelas/silver/08_dados_treino.sql.
-- Necessario porque o BigQuery rejeita subconsulta correlacionada por
-- desigualdade (data <= ...) que referencia a tabela diretamente ("Query
-- error: Correlated subqueries that reference other tables are not
-- supported unless they can be de-correlated"), confirmado em teste.
--
-- Nao faz: nao cria, nao altera nem substitui nenhuma tabela ou modelo.
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
  'silver.modelo_regressao_linear' AS modelo,
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
  MODEL `pdm-ceasa.silver.modelo_regressao_linear`,
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
