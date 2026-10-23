-- Conferencia de sql/construir_tabelas/silver/09_clima_historico_bronze_to_silver.sql.
-- Faz: compara contagem por estado entre bronze e silver (1 linha por
-- data/estado nas duas), prova calendario continuo (linhas = dias corridos),
-- chaves duplicadas, nulos nas 25 colunas de clima e faixa de valores da
-- janela de 3 dias.
-- Nao faz: nao cria nem substitui nenhuma tabela.

-- linhas por estado: bronze x silver (esperado: iguais) e continuidade
-- (esperado: linhas_silver = dias_corridos)
WITH bronze AS (
  SELECT estado, COUNT(*) AS linhas_bronze
  FROM `pdm-ceasa.bronze.clima_historico`
  GROUP BY estado
),
silver AS (
  SELECT
    estado,
    COUNT(*) AS linhas_silver,
    MIN(data) AS data_min,
    MAX(data) AS data_max,
    DATE_DIFF(MAX(data), MIN(data), DAY) + 1 AS dias_corridos
  FROM `pdm-ceasa.silver.clima_historico`
  GROUP BY estado
)
SELECT
  COALESCE(b.estado, s.estado) AS estado,
  b.linhas_bronze,
  s.linhas_silver,
  s.dias_corridos,
  s.data_min,
  s.data_max
FROM bronze AS b
FULL OUTER JOIN silver AS s ON s.estado = b.estado
ORDER BY estado;

-- chaves duplicadas (esperado: 0)
SELECT COUNT(*) AS chaves_duplicadas
FROM (
  SELECT estado, data, COUNT(*) AS n
  FROM `pdm-ceasa.silver.clima_historico`
  GROUP BY estado, data
  HAVING n > 1
);

-- nulos nas colunas de clima (esperado: 0 -- janela expansiva no inicio da
-- serie nao gera NULL)
SELECT
  COUNT(*) AS linhas,
  COUNTIF(temp_media_3d IS NULL) AS nulo_temp_media_3d,
  COUNTIF(umidade_media_3d IS NULL) AS nulo_umidade_media_3d,
  COUNTIF(nebulosidade_media_3d IS NULL) AS nulo_nebulosidade_media_3d,
  COUNTIF(precipitacao_mm_3d IS NULL) AS nulo_precipitacao_mm_3d,
  COUNTIF(vento_max_kmh_3d IS NULL) AS nulo_vento_max_kmh_3d,
  COUNTIF(temp_media_7d IS NULL) AS nulo_temp_media_7d,
  COUNTIF(umidade_media_7d IS NULL) AS nulo_umidade_media_7d,
  COUNTIF(nebulosidade_media_7d IS NULL) AS nulo_nebulosidade_media_7d,
  COUNTIF(precipitacao_mm_7d IS NULL) AS nulo_precipitacao_mm_7d,
  COUNTIF(vento_max_kmh_7d IS NULL) AS nulo_vento_max_kmh_7d,
  COUNTIF(temp_media_14d IS NULL) AS nulo_temp_media_14d,
  COUNTIF(umidade_media_14d IS NULL) AS nulo_umidade_media_14d,
  COUNTIF(nebulosidade_media_14d IS NULL) AS nulo_nebulosidade_media_14d,
  COUNTIF(precipitacao_mm_14d IS NULL) AS nulo_precipitacao_mm_14d,
  COUNTIF(vento_max_kmh_14d IS NULL) AS nulo_vento_max_kmh_14d,
  COUNTIF(temp_media_30d IS NULL) AS nulo_temp_media_30d,
  COUNTIF(umidade_media_30d IS NULL) AS nulo_umidade_media_30d,
  COUNTIF(nebulosidade_media_30d IS NULL) AS nulo_nebulosidade_media_30d,
  COUNTIF(precipitacao_mm_30d IS NULL) AS nulo_precipitacao_mm_30d,
  COUNTIF(vento_max_kmh_30d IS NULL) AS nulo_vento_max_kmh_30d,
  COUNTIF(temp_media_60d IS NULL) AS nulo_temp_media_60d,
  COUNTIF(umidade_media_60d IS NULL) AS nulo_umidade_media_60d,
  COUNTIF(nebulosidade_media_60d IS NULL) AS nulo_nebulosidade_media_60d,
  COUNTIF(precipitacao_mm_60d IS NULL) AS nulo_precipitacao_mm_60d,
  COUNTIF(vento_max_kmh_60d IS NULL) AS nulo_vento_max_kmh_60d
FROM `pdm-ceasa.silver.clima_historico`;

-- faixa de valores da janela de 3 dias, por estado
SELECT
  estado,
  MIN(temp_media_3d) AS temp_min, MAX(temp_media_3d) AS temp_max,
  MIN(umidade_media_3d) AS umidade_min, MAX(umidade_media_3d) AS umidade_max,
  MIN(nebulosidade_media_3d) AS nebulosidade_min, MAX(nebulosidade_media_3d) AS nebulosidade_max,
  MIN(precipitacao_mm_3d) AS precipitacao_min, MAX(precipitacao_mm_3d) AS precipitacao_max,
  MIN(vento_max_kmh_3d) AS vento_min, MAX(vento_max_kmh_3d) AS vento_max
FROM `pdm-ceasa.silver.clima_historico`
GROUP BY estado
ORDER BY estado;
