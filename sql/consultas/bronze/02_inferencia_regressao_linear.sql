-- Inferencia do modelo baseline.modelo_regressao_linear (LINEAR_REG,
-- treinado sobre bronze.cotacoes sem nenhum tratamento --
-- sql/modelo/bronze/02_baseline_treino_linear.sql). ML.PREDICT apenas le o
-- modelo ja treinado -- nao ha CREATE MODEL nesta consulta, nenhuma tabela
-- e criada ou alterada.
--
-- Fonte do vetor: pdm-ceasa.bronze.cotacoes (mesma fonte de
-- sql/modelo/bronze/01_baseline_dados_treino.sql). Vetor do baseline =
-- produto, classe, mes, dia_semana -- SEM preco e SEM lag (conferido no
-- script de treino, que so seleciona essas 4 colunas + alvo; "data" nao
-- entra no CREATE MODEL, so no WHERE do split -- achado registrado no
-- relatorio de entrega, nao corrigido aqui).
--
-- Achado de nomenclatura: bronze.produto e texto cru ("TOMATE SALADETE"),
-- diferente do produto normalizado da Silver ("tomate_saladete") usado como
-- parametro nas 9 consultas desta tarefa. Para aceitar o mesmo nome
-- normalizado aqui tambem, replica-se a MESMA transformacao de
-- sql/construir_tabelas/silver/02_normalizacao.sql (trim, colapsar espaco,
-- remover acento via NORMALIZE NFD, minuscula, espaco vira "_") sobre
-- bronze.produto, e busca-se a grafia bruta correspondente antes de
-- filtrar e antes de montar o vetor do ML.PREDICT.
--
-- Regra de data-base: data-base = p_data_alvo - 7 dias (passo do modelo).
-- Se nao houver pregao exatamente nessa data, usa-se a ultima cotacao real
-- anterior ou igual a ela -- mesma regra usada para montar dados_treino
-- (cada linha de features la vem de uma data com pregao real). mes e
-- dia_semana sao extraidos dessa data efetivamente encontrada
-- (data_base_usada), nunca de p_data_alvo -- vazamento seria usar a data
-- alvo ou uma data sem pregao real que o treino nunca veria.
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
  'baseline.modelo_regressao_linear' AS modelo,
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
  MODEL `pdm-ceasa.baseline.modelo_regressao_linear`,
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
