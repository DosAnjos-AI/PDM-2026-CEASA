-- Camada Bronze: carrega o CSV bruto do bucket para pdm-ceasa.bronze.cotacoes.
-- Dado como veio, sem tratamento, sem filtro. Nenhuma coluna é NOT NULL:
-- nulo é defeito a resolver na Silver, não motivo para rejeitar linha.
--
-- LOAD DATA OVERWRITE reconstrói a tabela inteira a cada execução (idempotente).
-- Origem por wildcard: um arquivo novo em gs://pdm-ceasa-dados/raw/ entra sem editar o script.
-- Sem tolerância a linha inválida (max_bad_records padrão = 0): a carga falha
-- em vez de descartar linha em silêncio.

LOAD DATA OVERWRITE `pdm-ceasa.bronze.cotacoes`
(
  data          DATE,
  ano           INT64,
  mes           INT64,
  dia           INT64,
  grupo         STRING,
  categoria     STRING,
  codigo        STRING,
  produto       STRING,
  embalagem     STRING,
  qtd_kg        NUMERIC,
  classe        INT64,
  preco_comum   NUMERIC,
  preco_maximo  NUMERIC,
  preco_minimo  NUMERIC,
  preco_kg      NUMERIC,
  layout        STRING,
  arquivo       STRING
)
FROM FILES (
  format = 'CSV',
  uris = ['gs://pdm-ceasa-dados/raw/*.csv'],
  skip_leading_rows = 1,
  field_delimiter = ',',
  quote = '"',
  encoding = 'UTF-8'
);
