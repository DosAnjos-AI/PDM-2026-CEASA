-- Camada Bronze: carrega o CSV bruto do bucket para bronze.cotacoes.
-- Dado como veio, sem tratamento, sem filtro. Nenhuma coluna é NOT NULL:
-- nulo é defeito a resolver na Silver, não motivo para rejeitar linha.
--
-- LOAD DATA OVERWRITE reconstrói a tabela inteira a cada execução (idempotente).
-- Origem por wildcard: um arquivo novo no prefixo raw/ entra sem editar o script.
-- Sem tolerância a linha inválida (max_bad_records padrão = 0): a carga falha
-- em vez de descartar linha em silêncio.
--
-- O bucket vem por parâmetro, não fica gravado aqui: cada projeto tem o seu.
--   bq query --project_id=<projeto> --use_legacy_sql=false \
--            --parameter='bucket:STRING:gs://<bucket>' < 01_bronze.sql
-- FROM FILES não aceita parâmetro na lista de uris, por isso o comando é
-- montado com FORMAT e executado por EXECUTE IMMEDIATE.
--
-- O nome do projeto também não aparece: `bronze.cotacoes` resolve contra o
-- projeto de --project_id. O mesmo vale para todo o restante do pipeline.

EXECUTE IMMEDIATE FORMAT("""
LOAD DATA OVERWRITE `bronze.cotacoes`
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
  uris = ['%s/raw/*.csv'],
  skip_leading_rows = 1,
  field_delimiter = ',',
  quote = '"',
  encoding = 'UTF-8'
)
""", @bucket);
