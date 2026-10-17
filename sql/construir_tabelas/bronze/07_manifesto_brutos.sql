-- Manifesto dos brutos: a lista de todo arquivo bruto (PDF, planilha, HTML)
-- que existe no bucket, por sede. Serve a conferencia de duas vias em
-- sql/consultas/bronze/05_ceasa_check.sql, que cruza esta lista com a coluna
-- arquivo de cada bronze.ceasa_<uf>.
--
-- Origem: gs://<bucket>/csv/manifesto_brutos.csv, gerado pelo entrypoint.sh a
-- cada execucao com o conteudo de DIR_BRUTO/<uf>/. Colunas:
--   sede     go, ms, sc, mg ou es
--   caminho  caminho do bruto relativo a pasta da sede, no mesmo formato da
--            coluna arquivo (na MS, arquivo ainda leva "#<aba>" no fim)
--
-- Retrato do momento, nao historico: LOAD DATA OVERWRITE refaz a tabela
-- inteira, que e pequena (uma linha por bruto).
--
-- O bucket vem por parametro, como em 01_bronze.sql:
--   bq query --project_id=<projeto> --use_legacy_sql=false \
--            --parameter='bucket:STRING:gs://<bucket>' < 07_manifesto_brutos.sql

EXECUTE IMMEDIATE FORMAT("""
LOAD DATA OVERWRITE `bronze.manifesto_brutos`
(
  sede    STRING,
  caminho STRING
)
FROM FILES (
  format = 'CSV',
  uris = ['%s/csv/manifesto_brutos.csv'],
  skip_leading_rows = 1,
  field_delimiter = ',',
  encoding = 'UTF-8'
)
""", @bucket);
