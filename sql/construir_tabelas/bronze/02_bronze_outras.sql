-- Camada Bronze das outras sedes (CEASA-MS, CEASA-SC, CEASA-MG e CEASA-ES):
-- carrega os CSVs de outras_ceasas/ para bronze.cotacoes_outras.
-- Dado como veio, sem tratamento, sem filtro, no esquema unico de 18 colunas
-- gerado por ingestao/scraping/comum.py. A coluna fonte identifica a sede.
--
-- Tabela separada de bronze.cotacoes de proposito: a CEASA-GO tem 17 colunas
-- proprias (categoria, codigo, classe, preco_kg, layout) das quais a Silver
-- e os modelos dependem. Misturar os dois formatos quebraria a carga da GO.
--
-- LOAD DATA OVERWRITE reconstroi a tabela inteira a cada execucao (idempotente).
-- Origem por wildcard: uma sede nova em outras_ceasas/ entra sem editar o script.
-- Sem tolerancia a linha invalida (max_bad_records padrao = 0): a carga falha
-- em vez de descartar linha em silencio.
--
-- O bucket vem por parametro, como em 01_bronze.sql:
--   bq query --project_id=<projeto> --use_legacy_sql=false \
--            --parameter='bucket:STRING:gs://<bucket>' < 02_bronze_outras.sql

EXECUTE IMMEDIATE FORMAT("""
LOAD DATA OVERWRITE `bronze.cotacoes_outras`
(
  data           DATE,
  ano            INT64,
  mes            INT64,
  dia            INT64,
  fonte          STRING,
  mercado        STRING,
  grupo          STRING,
  produto        STRING,
  classificacao  STRING,
  tipo           STRING,
  origem         STRING,
  embalagem      STRING,
  qtd_kg         NUMERIC,
  preco_minimo   NUMERIC,
  preco_comum    NUMERIC,
  preco_maximo   NUMERIC,
  situacao       STRING,
  arquivo        STRING
)
FROM FILES (
  format = 'CSV',
  uris = ['%s/outras_ceasas/*.csv'],
  skip_leading_rows = 1,
  field_delimiter = ',',
  quote = '"',
  encoding = 'UTF-8'
)
""", @bucket);
