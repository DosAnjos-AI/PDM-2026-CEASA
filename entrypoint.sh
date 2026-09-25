#!/usr/bin/env bash
# Ciclo diario de ingestao: coleta os PDFs novos, extrai o CSV, sobe para o
# bucket e reconstroi bronze, silver, gold e metricas no BigQuery.
#
# Idempotente de ponta a ponta: o scraper pula PDF que ja existe, o extrator e
# deterministico, o upload sobrescreve o mesmo objeto e todo .sql e
# LOAD DATA OVERWRITE ou CREATE OR REPLACE.
#
# Falha ruidosa: set -e aborta no primeiro erro em vez de seguir e deixar o
# BigQuery num estado meio reconstruido.
set -euo pipefail

# --- Configuracao (unica fonte dos valores usados abaixo) ---
PROJETO="${PROJETO:-pdm-caio-2026}"
BUCKET="${BUCKET:-gs://trabalho-pdm-caio}"
OBJETO_CSV="${OBJETO_CSV:-raw/cotacoes_site.csv}"
PDFS="${PDFS:-/mnt/pdfs/cotacoes}"
CSV="${CSV:-/tmp/cotacoes_site.csv}"
ANO_INICIAL="${ANO_INICIAL:-$(date +%Y)}"
# Falhas permanentes e conhecidas: os 2 boletins semanais comparativos
# (2022-04-08 e 2023-12-05), que nao sao cotacao diaria.
FALHAS_ESPERADAS="${FALHAS_ESPERADAS:-2}"

# Ordem dos .sql identica a documentada no README.md. sql/modelo/ fica de fora
# de proposito: cada arquivo la tem CREATE OR REPLACE MODEL e retreina ao rodar.
DIRETORIOS_SQL=(
    "sql/construir_tabelas/bronze"
    "sql/construir_tabelas/silver"
    "sql/construir_tabelas/gold"
    "sql/construir_tabelas/metricas"
)

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "== 1/4 coleta (a partir de ${ANO_INICIAL})"
python3 ingestao/ceasa_scraper.py --start-year "${ANO_INICIAL}" --out "${PDFS}"

echo "== 2/4 extracao"
python3 ingestao/ceasa_extrair.py --ocr \
        --entrada "${PDFS}" \
        --saida "${CSV}" \
        --falhas-esperadas "${FALHAS_ESPERADAS}"

echo "== 3/4 upload para ${BUCKET}/${OBJETO_CSV}"
gcloud storage cp "${CSV}" "${BUCKET}/${OBJETO_CSV}" --project="${PROJETO}"

echo "== 4/4 BigQuery"
for diretorio in "${DIRETORIOS_SQL[@]}"; do
    for arquivo in "${diretorio}"/*.sql; do
        # Aborta se o glob nao casar: diretorio vazio e erro de deploy, nao
        # motivo para pular silenciosamente uma camada inteira do pipeline.
        [[ -f "${arquivo}" ]] || { echo "ERRO: nenhum .sql em ${diretorio}" >&2; exit 1; }
        echo "-- ${arquivo}"
        # 01_bronze.sql e o unico que precisa saber o bucket: ele monta o
        # LOAD DATA com EXECUTE IMMEDIATE a partir deste parametro. Os demais
        # so usam dataset.tabela, resolvido por --project_id.
        if [[ "${arquivo}" == *"/bronze/01_bronze.sql" ]]; then
            bq query --project_id="${PROJETO}" --use_legacy_sql=false --quiet \
               --parameter="bucket:STRING:${BUCKET}" < "${arquivo}"
        else
            bq query --project_id="${PROJETO}" --use_legacy_sql=false --quiet < "${arquivo}"
        fi
    done
done

echo "== ciclo concluido"
