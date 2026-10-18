-- Boletins que ja estao na Bronze de cada sede, como caminho do bruto relativo
-- a pasta da sede (o "#<aba>" da MS sai, porque a planilha e o bruto).
--
-- Usada pelo entrypoint.sh antes da extracao: o extrator de cada sede so
-- processa os brutos que nao aparecem aqui, mais os dos ultimos meses. Rodar a
-- mao mostra o mesmo que o ciclo ve. Le so a coluna arquivo das tabelas.
--
-- A GO fica de fora: o CSV dela e sempre completo, porque tambem alimenta
-- bronze.cotacoes (01_bronze.sql), reescrita inteira a cada execucao.
--
--   bq query --project_id=<projeto> --use_legacy_sql=false --format=csv \
--            --max_rows=100000000 < 06_boletins_carregados.sql

SELECT DISTINCT sede, REGEXP_REPLACE(arquivo, r'#[0-9]+$', '') AS caminho
FROM (
  SELECT 'ms' AS sede, arquivo FROM `bronze.ceasa_ms`
  UNION ALL SELECT 'sc', arquivo FROM `bronze.ceasa_sc`
  UNION ALL SELECT 'mg', arquivo FROM `bronze.ceasa_mg`
  UNION ALL SELECT 'es', arquivo FROM `bronze.ceasa_es`
)
WHERE arquivo IS NOT NULL
ORDER BY sede, caminho;
