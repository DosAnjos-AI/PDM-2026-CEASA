-- Conferencia de ingestao/atualizar_clima.py (bronze.clima_historico).
-- Faz: contagem e periodo por estado e tipo de fonte, chaves duplicadas,
-- continuidade do calendario, nulos, faixa de valores, e prova de que a
-- previsao so ocupa datas posteriores ao ultimo observado ERA5 de cada
-- estado (o job so grava previsao a partir do dia seguinte ao ultimo
-- observado disponivel; previsao em data <= ultimo observado indicaria
-- troca nao feita).
-- Nao faz: nao cria nem substitui nenhuma tabela.

-- contagem e periodo por estado e fonte
SELECT
  estado,
  cidade,
  fonte,
  COUNT(*) AS linhas,
  MIN(data) AS data_min,
  MAX(data) AS data_max,
  MIN(data_coleta) AS coleta_min,
  MAX(data_coleta) AS coleta_max
FROM `pdm-ceasa.bronze.clima_historico`
GROUP BY estado, cidade, fonte
ORDER BY estado, data_min;

-- chaves duplicadas (esperado: 0)
SELECT COUNT(*) AS chaves_duplicadas
FROM (
  SELECT data, estado, COUNT(*) AS n
  FROM `pdm-ceasa.bronze.clima_historico`
  GROUP BY data, estado
  HAVING n > 1
);

-- continuidade do calendario por estado (esperado: linhas = dias_corridos)
SELECT
  estado,
  COUNT(*) AS linhas,
  DATE_DIFF(MAX(data), MIN(data), DAY) + 1 AS dias_corridos
FROM `pdm-ceasa.bronze.clima_historico`
GROUP BY estado
ORDER BY estado;

-- nulos (esperado: 0 em todas as colunas)
SELECT
  COUNT(*) AS linhas,
  COUNTIF(cidade IS NULL) AS nulo_cidade,
  COUNTIF(temp_media IS NULL) AS nulo_temp_media,
  COUNTIF(umidade_media IS NULL) AS nulo_umidade_media,
  COUNTIF(nebulosidade_media IS NULL) AS nulo_nebulosidade_media,
  COUNTIF(precipitacao_mm IS NULL) AS nulo_precipitacao_mm,
  COUNTIF(vento_max_kmh IS NULL) AS nulo_vento_max_kmh,
  COUNTIF(fonte IS NULL) AS nulo_fonte,
  COUNTIF(data_coleta IS NULL) AS nulo_data_coleta
FROM `pdm-ceasa.bronze.clima_historico`;

-- faixa de valores por tipo de fonte
SELECT
  SPLIT(fonte, '/')[OFFSET(0)] AS tipo_fonte,
  MIN(temp_media) AS temp_min, MAX(temp_media) AS temp_max,
  MIN(umidade_media) AS umidade_min, MAX(umidade_media) AS umidade_max,
  MIN(nebulosidade_media) AS nebulosidade_min, MAX(nebulosidade_media) AS nebulosidade_max,
  MIN(precipitacao_mm) AS precipitacao_min, MAX(precipitacao_mm) AS precipitacao_max,
  MIN(vento_max_kmh) AS vento_min, MAX(vento_max_kmh) AS vento_max
FROM `pdm-ceasa.bronze.clima_historico`
GROUP BY tipo_fonte
ORDER BY tipo_fonte;

-- previsao x ultimo observado por estado (esperado: previsao_em_data_observada
-- = 0 e primeira_previsao = ultimo_observado + 1 dia)
SELECT
  estado,
  MAX(IF(STARTS_WITH(fonte, 'open-meteo-archive-api'), data, NULL)) AS ultimo_observado,
  MIN(IF(STARTS_WITH(fonte, 'open-meteo-forecast-api'), data, NULL)) AS primeira_previsao,
  MAX(IF(STARTS_WITH(fonte, 'open-meteo-forecast-api'), data, NULL)) AS ultima_previsao,
  COUNTIF(
    STARTS_WITH(fonte, 'open-meteo-forecast-api')
    AND data <= (SELECT MAX(data) FROM `pdm-ceasa.bronze.clima_historico` AS o
                 WHERE o.estado = t.estado AND STARTS_WITH(o.fonte, 'open-meteo-archive-api'))
  ) AS previsao_em_data_observada
FROM `pdm-ceasa.bronze.clima_historico` AS t
GROUP BY estado
ORDER BY estado;
