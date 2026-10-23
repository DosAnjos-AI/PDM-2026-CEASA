-- Conferencia de sql/construir_tabelas/gold/06_ceasa_unificado_semanal_quinzenal.sql.
-- Faz: para gold.ceasa_unificado_semanal e gold.ceasa_unificado_quinzenal,
-- reporta contagem, produtos, periodo, chaves duplicadas, nulos nos precos
-- e faixa de dias_observados; prova que a soma de dias_observados bate com
-- COUNT(*) de silver.ceasa_unificado (nenhum dia perdido ou duplicado na
-- agregacao).
-- Nao faz: nao cria nem substitui nenhuma tabela.

-- soma de dias_observados x linhas da silver (esperado: as tres iguais)
SELECT
  (SELECT COUNT(*) FROM `pdm-ceasa.silver.ceasa_unificado`) AS linhas_silver,
  (SELECT SUM(dias_observados) FROM `pdm-ceasa.gold.ceasa_unificado_semanal`) AS dias_semanal,
  (SELECT SUM(dias_observados) FROM `pdm-ceasa.gold.ceasa_unificado_quinzenal`) AS dias_quinzenal;

-- SEMANAL: visao geral (esperado: dias_observados entre 1 e 7)
SELECT
  COUNT(*) AS linhas,
  COUNT(DISTINCT produto_canonico) AS produtos_distintos,
  COUNT(DISTINCT ceasa) AS ceasas_distintas,
  MIN(semana_inicio) AS semana_min,
  MAX(semana_inicio) AS semana_max,
  MIN(dias_observados) AS dias_obs_min,
  MAX(dias_observados) AS dias_obs_max,
  COUNTIF(preco_minimo IS NULL) AS nulo_preco_minimo,
  COUNTIF(preco_comum IS NULL) AS nulo_preco_comum,
  COUNTIF(preco_maximo IS NULL) AS nulo_preco_maximo
FROM `pdm-ceasa.gold.ceasa_unificado_semanal`;

-- SEMANAL: chaves duplicadas (esperado: 0)
SELECT COUNT(*) AS chaves_duplicadas_semanal
FROM (
  SELECT ceasa, produto_canonico, ano_iso, semana_iso, COUNT(*) AS n
  FROM `pdm-ceasa.gold.ceasa_unificado_semanal`
  GROUP BY ceasa, produto_canonico, ano_iso, semana_iso
  HAVING n > 1
);

-- QUINZENAL: visao geral (esperado: dias_observados entre 1 e 16)
SELECT
  COUNT(*) AS linhas,
  COUNT(DISTINCT produto_canonico) AS produtos_distintos,
  COUNT(DISTINCT ceasa) AS ceasas_distintas,
  MIN(DATE(ano, mes, 1)) AS mes_min,
  MAX(DATE(ano, mes, 1)) AS mes_max,
  MIN(dias_observados) AS dias_obs_min,
  MAX(dias_observados) AS dias_obs_max,
  COUNTIF(preco_minimo IS NULL) AS nulo_preco_minimo,
  COUNTIF(preco_comum IS NULL) AS nulo_preco_comum,
  COUNTIF(preco_maximo IS NULL) AS nulo_preco_maximo
FROM `pdm-ceasa.gold.ceasa_unificado_quinzenal`;

-- QUINZENAL: chaves duplicadas (esperado: 0)
SELECT COUNT(*) AS chaves_duplicadas_quinzenal
FROM (
  SELECT ceasa, produto_canonico, ano, mes, quinzena, COUNT(*) AS n
  FROM `pdm-ceasa.gold.ceasa_unificado_quinzenal`
  GROUP BY ceasa, produto_canonico, ano, mes, quinzena
  HAVING n > 1
);
