#!/usr/bin/env bash
# Cria o disparo por evento do Workflow verificar-e-atualizar-prata-ouro:
#   log sink (tableDataChange so em bronze.ceasa_<uf>) -> topico Pub/Sub ->
#   gatilho Eventarc -> Workflow (decide pela consulta de defasagem).
#
# O evento so acorda o Workflow; quem decide o que reconstruir e o estado da
# cadeia (25_defasagem_cadeia_check.sql). Por isso a mensagem nao e lida.
#
# Ordem de proposito: assinatura (criada pelo gatilho) ANTES do sink. Um
# topico sem assinatura descarta a mensagem -- foi assim que um evento se
# perdeu em 02/11.
# O filtro do sink cobre so bronze: o job escreve em silver e gold, e um
# filtro que os alcancasse faria a cadeia disparar a si mesma.
# Nenhum papel com condicao IAM. A identidade do sink (compartilhada com o
# sink do MLOps) recebe papel so no topico novo, nunca no projeto.
#
# Idempotente: cada recurso so e criado se nao existir; os bindings IAM nao
# duplicam. Falha ruidosa: set -e.
# Requer bash + gcloud (Linux; no Windows, via WSL ou Git Bash).
#
# Uso (a partir de qualquer diretorio, com conta que administre o projeto):
#   pipelines/criar_gatilho_evento.sh
set -euo pipefail

# --- Variaveis ---
PROJETO="${PROJETO:-pdm-ceasa}"
REGIAO="${REGIAO:-us-central1}"
SA="prata-ouro-evento@${PROJETO}.iam.gserviceaccount.com"
WORKFLOW="verificar-e-atualizar-prata-ouro"
GATILHO="${WORKFLOW}-trigger"
TOPICO="bronze-ceasa-alterada"
DLQ="${TOPICO}-dlq"
SINK="${TOPICO}"
TENTATIVAS=5
FILTRO_SINK='logName="projects/pdm-ceasa/logs/cloudaudit.googleapis.com%2Fdata_access"
protoPayload.serviceName="bigquery.googleapis.com"
protoPayload.metadata.tableDataChange:*
protoPayload.resourceName=~"^projects/pdm-ceasa/datasets/bronze/tables/ceasa_(go|sc|ms|mg|es)$"'

g() { gcloud --project="${PROJETO}" --quiet "$@"; }

echo "== papel do gatilho (receber evento do Eventarc)"
g projects add-iam-policy-binding "${PROJETO}" --member="serviceAccount:${SA}" \
    --role=roles/eventarc.eventReceiver --condition=None --format=none

echo "== topico, DLQ e assinatura da DLQ (guarda o que falhar)"
g pubsub topics describe "${TOPICO}" >/dev/null 2>&1 || g pubsub topics create "${TOPICO}"
g pubsub topics describe "${DLQ}" >/dev/null 2>&1 || g pubsub topics create "${DLQ}"
g pubsub subscriptions describe "${DLQ}-sub" >/dev/null 2>&1 || \
    g pubsub subscriptions create "${DLQ}-sub" --topic="${DLQ}"

echo "== gatilho Eventarc (cria a assinatura do topico)"
g eventarc triggers describe "${GATILHO}" --location="${REGIAO}" >/dev/null 2>&1 || \
    g eventarc triggers create "${GATILHO}" --location="${REGIAO}" \
        --destination-workflow="${WORKFLOW}" --destination-workflow-location="${REGIAO}" \
        --event-filters="type=google.cloud.pubsub.topic.v1.messagePublished" \
        --transport-topic="projects/${PROJETO}/topics/${TOPICO}" \
        --service-account="${SA}"
ASSINATURA="$(g eventarc triggers describe "${GATILHO}" --location="${REGIAO}" --format='value(transport.pubsub.subscription)')"
[[ -n "${ASSINATURA}" ]] || { echo "ERRO: gatilho sem assinatura" >&2; exit 1; }

echo "== DLQ na assinatura do gatilho: ${ASSINATURA}"
NUMERO="$(g projects describe "${PROJETO}" --format='value(projectNumber)')"
AGENTE_PUBSUB="service-${NUMERO}@gcp-sa-pubsub.iam.gserviceaccount.com"
g pubsub subscriptions update "${ASSINATURA}" --dead-letter-topic="${DLQ}" --max-delivery-attempts="${TENTATIVAS}"
g pubsub topics add-iam-policy-binding "${DLQ}" --member="serviceAccount:${AGENTE_PUBSUB}" \
    --role=roles/pubsub.publisher --format=none
g pubsub subscriptions add-iam-policy-binding "${ASSINATURA}" --member="serviceAccount:${AGENTE_PUBSUB}" \
    --role=roles/pubsub.subscriber --format=none

echo "== log sink (por ultimo: a assinatura ja existe)"
g logging sinks describe "${SINK}" >/dev/null 2>&1 || \
    g logging sinks create "${SINK}" "pubsub.googleapis.com/projects/${PROJETO}/topics/${TOPICO}" \
        --log-filter="${FILTRO_SINK}" \
        --description="tableDataChange em bronze.ceasa_<uf> -> Workflow ${WORKFLOW}"
IDENTIDADE_SINK="$(g logging sinks describe "${SINK}" --format='value(writerIdentity)')"
g pubsub topics add-iam-policy-binding "${TOPICO}" --member="${IDENTIDADE_SINK}" \
    --role=roles/pubsub.publisher --format=none

echo "ok: ${SINK} -> ${TOPICO} -> ${GATILHO} -> ${WORKFLOW}"
