-- Camada Bronze da CEASA-GO: mantem bronze.ceasa_go em dia com todos os
-- brutos da sede no bucket, gravando so o que mudou.
--
-- Origem: gs://<bucket>/raw/cotacoes_site.csv, gerado por
-- ingestao/ceasa_extrair.py (17 colunas proprias da GO). O mesmo CSV segue
-- alimentando bronze.cotacoes por 01_bronze.sql, que nao muda.
-- O CSV e refeito a cada execucao a partir de TODOS os brutos da sede, nao so
-- dos baixados no dia; por isso um boletim que ficou fora de uma carga
-- anterior entra na proxima.
--
-- Chave de atualizacao: a coluna arquivo, que identifica um boletim (um PDF,
-- uma aba de planilha ou um HTML). Cada boletim ganha uma impressao digital
-- (hash do conteudo de todas as suas linhas), calculada igual no CSV e na
-- tabela. A cada execucao:
--   - boletim do CSV ausente da tabela      -> entra;
--   - boletim com impressao diferente       -> suas linhas sao substituidas
--                                              (pega correcao da fonte);
--   - boletim com a mesma impressao         -> nao e tocado;
--   - linha da tabela cujo arquivo nao esta no CSV -> fica intocada.
-- Sem nada novo ou alterado, o MERGE nem roda. Reexecutar com o mesmo CSV nao
-- muda nada (idempotente).
--
-- Passos: o CSV vai para bronze.stg_ceasa_go (LOAD DATA OVERWRITE, refeita a
-- cada execucao), a comparacao das impressoes separa os boletins novos e os
-- alterados, e um unico MERGE aplica a troca so neles. MERGE e atomico: ou
-- entra tudo, ou nada muda. Sem tolerancia a linha invalida
-- (max_bad_records = 0). A ultima consulta imprime quantos boletins entraram e
-- quantos foram substituidos.
--
-- As colunas sao sempre citadas pelo nome, nunca por posicao: se a tabela
-- existente tiver esquema diferente, o MERGE falha em vez de gravar coluna
-- trocada.
--
-- O bucket vem por parametro, como em 01_bronze.sql:
--   bq query --project_id=<projeto> --use_legacy_sql=false \
--            --parameter='bucket:STRING:gs://<bucket>' < 02_ceasa_go.sql

DECLARE boletins_novos ARRAY<STRING>;
DECLARE boletins_alterados ARRAY<STRING>;

EXECUTE IMMEDIATE FORMAT("""
LOAD DATA OVERWRITE `bronze.stg_ceasa_go`
(
  data         DATE,
  ano          INT64,
  mes          INT64,
  dia          INT64,
  grupo        STRING,
  categoria    STRING,
  codigo       STRING,
  produto      STRING,
  embalagem    STRING,
  qtd_kg       NUMERIC,
  classe       INT64,
  preco_comum  NUMERIC,
  preco_maximo NUMERIC,
  preco_minimo NUMERIC,
  preco_kg     NUMERIC,
  layout       STRING,
  arquivo      STRING
)
FROM FILES (
  format = 'CSV',
  uris = ['%s/raw/cotacoes_site.csv'],
  skip_leading_rows = 1,
  field_delimiter = ',',
  quote = '"',
  encoding = 'UTF-8'
)
""", @bucket);

-- Primeira execucao em projeto novo: cria a tabela vazia com o esquema da sede.
CREATE TABLE IF NOT EXISTS `bronze.ceasa_go`
(
  data         DATE,
  ano          INT64,
  mes          INT64,
  dia          INT64,
  grupo        STRING,
  categoria    STRING,
  codigo       STRING,
  produto      STRING,
  embalagem    STRING,
  qtd_kg       NUMERIC,
  classe       INT64,
  preco_comum  NUMERIC,
  preco_maximo NUMERIC,
  preco_minimo NUMERIC,
  preco_kg     NUMERIC,
  layout       STRING,
  arquivo      STRING
);

-- Impressao digital por boletim: as linhas viram texto JSON, ordenadas para
-- que a ordem no CSV nao importe, e o conjunto vira um hash. Linhas repetidas
-- dentro do boletim contam (STRING_AGG nao deduplica). Da tabela so entram os
-- boletins que estao no CSV.
SET (boletins_novos, boletins_alterados) = (
  WITH
  stg AS (
    SELECT arquivo, FARM_FINGERPRINT(STRING_AGG(linha, '\n' ORDER BY linha)) AS impressao
    FROM (SELECT arquivo, TO_JSON_STRING(STRUCT(data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem, qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg, layout, arquivo)) AS linha
          FROM `bronze.stg_ceasa_go`)
    GROUP BY arquivo
  ),
  tabela AS (
    SELECT arquivo, FARM_FINGERPRINT(STRING_AGG(linha, '\n' ORDER BY linha)) AS impressao
    FROM (SELECT arquivo, TO_JSON_STRING(STRUCT(data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem, qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg, layout, arquivo)) AS linha
          FROM `bronze.ceasa_go`
          WHERE arquivo IN (SELECT arquivo FROM `bronze.stg_ceasa_go`))
    GROUP BY arquivo
  )
  SELECT AS STRUCT
    IFNULL(ARRAY_AGG(IF(tabela.arquivo IS NULL, stg.arquivo, NULL) IGNORE NULLS), ARRAY<STRING>[]),
    IFNULL(ARRAY_AGG(IF(tabela.impressao != stg.impressao, stg.arquivo, NULL) IGNORE NULLS), ARRAY<STRING>[])
  FROM stg
  LEFT JOIN tabela USING (arquivo)
);

IF ARRAY_LENGTH(boletins_novos) + ARRAY_LENGTH(boletins_alterados) > 0 THEN
  MERGE `bronze.ceasa_go` AS t
  USING `bronze.stg_ceasa_go` AS s
  ON FALSE
  WHEN NOT MATCHED BY SOURCE AND t.arquivo IN UNNEST(boletins_alterados) THEN
    DELETE
  WHEN NOT MATCHED BY TARGET
       AND (s.arquivo IN UNNEST(boletins_novos) OR s.arquivo IN UNNEST(boletins_alterados)) THEN
    INSERT (data, ano, mes, dia, grupo, categoria, codigo, produto, embalagem, qtd_kg, classe, preco_comum, preco_maximo, preco_minimo, preco_kg, layout, arquivo)
    VALUES (s.data, s.ano, s.mes, s.dia, s.grupo, s.categoria, s.codigo, s.produto, s.embalagem, s.qtd_kg, s.classe, s.preco_comum, s.preco_maximo, s.preco_minimo, s.preco_kg, s.layout, s.arquivo);
END IF;

SELECT 'ceasa_go' AS tabela,
       ARRAY_LENGTH(boletins_novos) AS boletins_inseridos,
       ARRAY_LENGTH(boletins_alterados) AS boletins_substituidos;
