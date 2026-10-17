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
#   CEASA-GO  go/  -> raw/cotacoes_site.csv -> bronze.ceasa_go (e bronze.cotacoes)
#   CEASA-MS  ms/  -> csv/ceasa_ms.csv      -> bronze.ceasa_ms
#   CEASA-SC  sc/  -> csv/ceasa_sc.csv      -> bronze.ceasa_sc
#   CEASA-MG  mg/  -> csv/ceasa_mg.csv      -> bronze.ceasa_mg
#   CEASA-ES  es/  -> csv/ceasa_es.csv      -> bronze.ceasa_es
# Cada CSV e refeito com TODOS os brutos da sede, nao so os do dia, e
# bronze.ceasa_<uf> recebe dele so o necessario, por MERGE na coluna arquivo:
# boletim ausente entra, boletim com conteudo diferente e substituido, o resto
# nao e tocado. Assim a tabela acompanha o bucket mesmo depois de uma execucao
# que baixou e nao carregou.
#
# Conferencia de duas vias: csv/manifesto_brutos.csv lista todo bruto do
# bucket; sql/consultas/bronze/05_ceasa_check.sql cruza essa lista com as
# tabelas (bruto sem linha no BigQuery e linha no BigQuery sem bruto).
#
# Idempotente de ponta a ponta: coletor pula bruto existente, extrator e
# deterministico, upload sobrescreve o mesmo objeto e todo .sql e
# LOAD DATA OVERWRITE, CREATE OR REPLACE ou MERGE que nao muda nada quando o
# CSV e o mesmo.
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
PREFIXO_CSV="${PREFIXO_CSV:-csv}"
# Primeiro ano que o scraper da CEASA-GO percorre. Na carga inicial use 2019.
# No ciclo diario o padrao e o ano anterior, para que a virada de ano nao perca
# boletim de dezembro publicado com atraso; o que ja existe e pulado. As outras
# sedes sempre percorrem o historico inteiro e pulam o que ja existe.
ANO_INICIAL_GO="${ANO_INICIAL_GO:-$(( $(date +%Y) - 1 ))}"
# Falhas permanentes e conhecidas da CEASA-GO: os 2 boletins semanais
# comparativos (2022-04-08 e 2023-12-05), que nao sao cotacao diaria.
FALHAS_ESPERADAS_GO="${FALHAS_ESPERADAS_GO:-2}"
# Sedes alem da GO, coletadas por ingestao/scraping/ceasa_<uf>.py.
SEDES=(${SEDES:-ms sc mg es})
# Extensoes do bruto de cada sede, as mesmas que o extrator dela le; definem o
# que entra no manifesto.
declare -A EXTENSOES_BRUTO=([go]="pdf" [ms]="xls xlsx" [sc]="pdf" [mg]="html" [es]="html")
OBJETO_MANIFESTO="${OBJETO_MANIFESTO:-${PREFIXO_CSV}/manifesto_brutos.csv}"

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

# Configuracao incompleta aborta antes de baixar ou enviar qualquer coisa.
for uf in go "${SEDES[@]}"; do
    [[ -n "${EXTENSOES_BRUTO[${uf}]:-}" ]] || { echo "ERRO: sem extensao de bruto para ${uf} em EXTENSOES_BRUTO" >&2; exit 1; }
done

echo "== 1/5 CEASA-GO: coleta (a partir de ${ANO_INICIAL_GO}), extracao e upload"
python3 ingestao/ceasa_scraper.py --start-year "${ANO_INICIAL_GO}" --out "${DIR_BRUTO}/go"
python3 ingestao/ceasa_extrair.py --ocr \
        --entrada "${DIR_BRUTO}/go" \
        --saida "${DIR_CSV}/cotacoes_site.csv" \
        --falhas-esperadas "${FALHAS_ESPERADAS_GO}"
gcloud storage cp "${DIR_CSV}/cotacoes_site.csv" "${BUCKET}/${OBJETO_CSV_GO}" --project="${PROJETO}"

echo "== 2/5 demais sedes: ${SEDES[*]}"
sedes_com_falha=()
# Sedes cujo CSV foi enviado nesta execucao; so elas tem a Bronze atualizada.
sedes_enviadas=(go)
for uf in "${SEDES[@]}"; do
    echo "-- ceasa_${uf}"
    csv="${DIR_CSV}/cotacoes_${uf}.csv"
    # O if desliga o set -e so para esta chamada: a falha de uma sede nao
    # derruba as outras nem a CEASA-GO, mas e registrada e reportada no fim.
    if python3 "ingestao/scraping/ceasa_${uf}.py" \
            --bruto "${DIR_BRUTO}/${uf}" \
            --saida "${csv}"; then
        gcloud storage cp "${csv}" "${BUCKET}/${PREFIXO_CSV}/ceasa_${uf}.csv" --project="${PROJETO}"
        sedes_enviadas+=("${uf}")
    else
        echo "ERRO: ceasa_${uf} falhou; o CSV anterior dela continua no bucket" >&2
        sedes_com_falha+=("${uf}")
    fi
done

echo "== 3/5 manifesto dos brutos"
# Lista todo bruto que existe agora, de todas as sedes, inclusive a que falhou
# nesta execucao: a conferencia mostra entao o que ficou sem carregar.
manifesto="${DIR_CSV}/manifesto_brutos.csv"
echo "sede,caminho" > "${manifesto}"
for uf in go "${SEDES[@]}"; do
    # Sede que nunca baixou nada nao tem pasta; entra no manifesto com zero.
    [[ -d "${DIR_BRUTO}/${uf}" ]] || { echo "-- ${uf}: 0 bruto(s)"; continue; }
    filtro=()
    for ext in ${EXTENSOES_BRUTO[${uf}]}; do
        (( ${#filtro[@]} )) && filtro+=(-o)
        filtro+=(-iname "*.${ext}")
    done
    # %P = caminho relativo a pasta da sede, o mesmo formato da coluna arquivo;
    # -H segue a pasta da sede se ela for um link simbolico
    find -H "${DIR_BRUTO}/${uf}" -type f \( "${filtro[@]}" \) -printf "${uf},%P\n" | LC_ALL=C sort >> "${manifesto}"
    echo "-- ${uf}: $(grep -c "^${uf}," "${manifesto}" || true) bruto(s)"
done
# O CSV do manifesto nao usa aspas: cada linha tem exatamente uma virgula, a
# que separa sede e caminho. Caminho com virgula ou aspas quebraria a carga.
if tail -n +2 "${manifesto}" | grep -q -e '"' -e ',.*,'; then
    echo "ERRO: caminho de bruto com virgula ou aspas em ${manifesto}" >&2
    exit 1
fi
gcloud storage cp "${manifesto}" "${BUCKET}/${OBJETO_MANIFESTO}" --project="${PROJETO}"

echo "== 4/5 BigQuery"
for diretorio in "${DIRETORIOS_SQL[@]}"; do
    for arquivo in "${diretorio}"/*.sql; do
        # Aborta se o glob nao casar: diretorio vazio e erro de deploy, nao
        # motivo para pular silenciosamente uma camada inteira do pipeline.
        [[ -f "${arquivo}" ]] || { echo "ERRO: nenhum .sql em ${diretorio}" >&2; exit 1; }
        # Script de uma sede (NN_ceasa_<uf>.sql) que nao foi coletada com
        # sucesso agora e pulado: o CSV dela pode nem existir no bucket, e a
        # tabela fica como estava em vez de derrubar o resto do pipeline.
        if [[ "$(basename "${arquivo}")" =~ ^[0-9]+_ceasa_([a-z]{2})\.sql$ ]] \
           && [[ " ${sedes_enviadas[*]} " != *" ${BASH_REMATCH[1]} "* ]]; then
            echo "-- ${arquivo} (pulado: ceasa_${BASH_REMATCH[1]} nao foi enviada nesta execucao)"
            continue
        fi
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

echo "== 5/5 resumo"
if (( ${#sedes_com_falha[@]} > 0 )); then
    echo "ERRO: sede(s) com falha, nao atualizada(s) no bucket: ${sedes_com_falha[*]}" >&2
    exit 1
fi
echo "== ciclo concluido"
