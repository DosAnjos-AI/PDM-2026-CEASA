#!/usr/bin/env bash
# Ciclo de ingestao: coleta o que ainda nao foi baixado, extrai os CSVs, sobe
# para o bucket e reconstroi bronze, silver e gold no BigQuery.
#
# O mesmo script serve a carga inicial e ao ciclo diario. Todo coletor pula o
# arquivo bruto que ja existe em DIR_BRUTO, entao a primeira execucao baixa o
# historico inteiro e as seguintes so o que e novo, desde que DIR_BRUTO
# persista entre execucoes (bucket montado no Cloud Run, pasta do home no
# Cloud Shell).
#
# Sedes (bruto em DIR_BRUTO/<uf>/, organizado por ano e mes dentro dela):
#   CEASA-GO          go/          -> raw/cotacoes_site.csv            -> bronze.cotacoes
#   CEASA-MS/SC/MG/ES ms/ sc/ mg/ es/ -> outras_ceasas/cotacoes_<uf>.csv -> bronze.cotacoes_outras
#
# Idempotente de ponta a ponta: coletor pula bruto existente, extrator e
# deterministico, upload sobrescreve o mesmo objeto e todo .sql e
# LOAD DATA OVERWRITE ou CREATE OR REPLACE.
#
# Falha ruidosa: set -e aborta no primeiro erro da CEASA-GO ou do BigQuery.
# Uma outra sede que falha nao e enviada (o objeto anterior dela fica no
# bucket), as demais seguem, e o script termina com codigo 1 nomeando-a.
set -euo pipefail

# --- Configuracao (unica fonte dos valores usados abaixo) ---
PROJETO="${PROJETO:-pdm-ceasa}"
BUCKET="${BUCKET:-gs://pdm-ceasa-dados}"
# Pasta persistente dos brutos (PDFs, planilhas, HTML), uma subpasta por sede.
# No Cloud Run e gs://<bucket>/cotacoes/ montado; no Cloud Shell, ~/cotacoes.
DIR_BRUTO="${DIR_BRUTO:-/mnt/dados}"
# Pasta dos CSVs gerados; sao refeitos do zero a cada execucao.
DIR_CSV="${DIR_CSV:-/tmp}"
OBJETO_CSV_GO="${OBJETO_CSV_GO:-raw/cotacoes_site.csv}"
PREFIXO_OUTRAS="${PREFIXO_OUTRAS:-outras_ceasas}"
# Primeiro ano que o scraper da CEASA-GO percorre. Na carga inicial use 2019.
# No ciclo diario o padrao e o ano anterior, para que a virada de ano nao perca
# boletim de dezembro publicado com atraso; o que ja existe e pulado. As outras
# sedes sempre percorrem o historico inteiro e pulam o que ja existe.
ANO_INICIAL_GO="${ANO_INICIAL_GO:-$(( $(date +%Y) - 1 ))}"
# Falhas permanentes e conhecidas da CEASA-GO: os 2 boletins semanais
# comparativos (2022-04-08 e 2023-12-05), que nao sao cotacao diaria.
FALHAS_ESPERADAS_GO="${FALHAS_ESPERADAS_GO:-2}"
# Sedes coletadas por ingestao/scraping/ceasa_<uf>.py.
SEDES_OUTRAS=(${SEDES_OUTRAS:-ms sc mg es})

# Ordem dos .sql identica a documentada no README.md.
#
# Duas pastas ficam de fora do ciclo, pelo mesmo motivo: dependem de treino
# de modelo, que nao e rotina.
#   sql/modelo/     -> cada arquivo tem CREATE OR REPLACE MODEL e retreina.
#   .../metricas/   -> avalia os 12 modelos com ML.EVALUATE. Sem os modelos
#                      treinados ela falha com "Not found: Model"; e com eles,
#                      so muda quando ha retreino. Rodar todo dia nao agrega.
DIRETORIOS_SQL=(
    "sql/construir_tabelas/bronze"
    "sql/construir_tabelas/silver"
    "sql/construir_tabelas/gold"
)

cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p "${DIR_BRUTO}" "${DIR_CSV}"

echo "== 1/4 CEASA-GO: coleta (a partir de ${ANO_INICIAL_GO}), extracao e upload"
python3 ingestao/ceasa_scraper.py --start-year "${ANO_INICIAL_GO}" --out "${DIR_BRUTO}/go"
python3 ingestao/ceasa_extrair.py --ocr \
        --entrada "${DIR_BRUTO}/go" \
        --saida "${DIR_CSV}/cotacoes_site.csv" \
        --falhas-esperadas "${FALHAS_ESPERADAS_GO}"
gcloud storage cp "${DIR_CSV}/cotacoes_site.csv" "${BUCKET}/${OBJETO_CSV_GO}" --project="${PROJETO}"

echo "== 2/4 outras sedes: ${SEDES_OUTRAS[*]}"
sedes_com_falha=()
for uf in "${SEDES_OUTRAS[@]}"; do
    echo "-- ceasa_${uf}"
    csv="${DIR_CSV}/cotacoes_${uf}.csv"
    # O if desliga o set -e so para esta chamada: a falha de uma sede nao
    # derruba as outras nem a CEASA-GO, mas e registrada e reportada no fim.
    if python3 "ingestao/scraping/ceasa_${uf}.py" \
            --bruto "${DIR_BRUTO}/${uf}" \
            --saida "${csv}"; then
        gcloud storage cp "${csv}" "${BUCKET}/${PREFIXO_OUTRAS}/cotacoes_${uf}.csv" --project="${PROJETO}"
    else
        echo "ERRO: ceasa_${uf} falhou; o CSV anterior dela continua no bucket" >&2
        sedes_com_falha+=("${uf}")
    fi
done

echo "== 3/4 BigQuery"
for diretorio in "${DIRETORIOS_SQL[@]}"; do
    for arquivo in "${diretorio}"/*.sql; do
        # Aborta se o glob nao casar: diretorio vazio e erro de deploy, nao
        # motivo para pular silenciosamente uma camada inteira do pipeline.
        [[ -f "${arquivo}" ]] || { echo "ERRO: nenhum .sql em ${diretorio}" >&2; exit 1; }
        echo "-- ${arquivo}"
        # Os scripts da Bronze sao os unicos que precisam saber o bucket: eles
        # montam o LOAD DATA com EXECUTE IMMEDIATE a partir deste parametro. Os
        # demais so usam dataset.tabela, resolvido por --project_id.
        if [[ "${arquivo}" == */construir_tabelas/bronze/* ]]; then
            bq query --project_id="${PROJETO}" --use_legacy_sql=false --quiet \
               --parameter="bucket:STRING:${BUCKET}" < "${arquivo}"
        else
            bq query --project_id="${PROJETO}" --use_legacy_sql=false --quiet < "${arquivo}"
        fi
    done
done

echo "== 4/4 resumo"
if (( ${#sedes_com_falha[@]} > 0 )); then
    echo "ERRO: sede(s) com falha, nao atualizada(s) no bucket: ${sedes_com_falha[*]}" >&2
    exit 1
fi
echo "== ciclo concluido"
