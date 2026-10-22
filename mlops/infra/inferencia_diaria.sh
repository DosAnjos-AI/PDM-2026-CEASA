#!/usr/bin/env bash
# Inferência diária orientada a eventos (idempotente: reexecutar não duplica nada).
#
#   silver.ceasa_unificado regravada --log de auditoria--> coletor de logs --publica-->
#   tópico ceasa-dados-atualizados --Eventarc--> Workflow inferencia-diaria
#       --executa--> job treino-precos com "pipeline.prever"
#
# Uso (de dentro da pasta mlops, com credenciais de quem administra o projeto):
#     bash infra/inferencia_diaria.sh
# Roda em Linux, macOS e Git Bash. No PowerShell, os mesmos comandos gcloud funcionam um a um.
set -euo pipefail

PROJETO="pdm-ceasa"
REGIAO="us-central1"
TOPICO="ceasa-dados-atualizados"
DLQ="${TOPICO}-dlq"
JOB="treino-precos"
WORKFLOW="inferencia-diaria"
CONTA="inferencia-diaria@${PROJETO}.iam.gserviceaccount.com"     # Eventarc + Workflow
CONTA_JOB="airflow-mlops@${PROJETO}.iam.gserviceaccount.com"      # conta com que o job roda
CONTA_INGESTAO="ciclo-ceasa@${PROJETO}.iam.gserviceaccount.com"   # quem publica o aviso
PASTA="$(cd "$(dirname "$0")" && pwd)"

gcloud services enable pubsub.googleapis.com eventarc.googleapis.com workflows.googleapis.com \
    workflowexecutions.googleapis.com --project "$PROJETO"

# Conta de serviço do gatilho e do workflow
gcloud iam service-accounts describe "$CONTA" --project "$PROJETO" >/dev/null 2>&1 ||
    gcloud iam service-accounts create "${CONTA%%@*}" --project "$PROJETO" \
        --display-name "Inferência diária (Pub/Sub -> Workflow -> job)"
for papel in roles/workflows.invoker roles/eventarc.eventReceiver roles/logging.logWriter; do
    gcloud projects add-iam-policy-binding "$PROJETO" --member "serviceAccount:$CONTA" --role "$papel" \
        --condition=None --format none
done
# Executar o job com outros argumentos exige run.jobs.runWithOverrides (papel run.developer, só neste job)
gcloud run jobs add-iam-policy-binding "$JOB" --region "$REGIAO" --project "$PROJETO" \
    --member "serviceAccount:$CONTA" --role roles/run.developer --format none
gcloud iam service-accounts add-iam-policy-binding "$CONTA_JOB" --project "$PROJETO" \
    --member "serviceAccount:$CONTA" --role roles/iam.serviceAccountUser --format none

# Tópico, fila de erros (DLQ) e uma assinatura para guardar as mensagens que falharem
gcloud pubsub topics describe "$TOPICO" --project "$PROJETO" >/dev/null 2>&1 ||
    gcloud pubsub topics create "$TOPICO" --project "$PROJETO"
gcloud pubsub topics describe "$DLQ" --project "$PROJETO" >/dev/null 2>&1 ||
    gcloud pubsub topics create "$DLQ" --project "$PROJETO"
gcloud pubsub subscriptions describe "${DLQ}-sub" --project "$PROJETO" >/dev/null 2>&1 ||
    gcloud pubsub subscriptions create "${DLQ}-sub" --topic "$DLQ" --project "$PROJETO"

# A ingestão do grupo pode publicar no tópico (opcional: o coletor de logs abaixo já publica)
gcloud pubsub topics add-iam-policy-binding "$TOPICO" --project "$PROJETO" \
    --member "serviceAccount:$CONTA_INGESTAO" --role roles/pubsub.publisher --format none

# Coletor de logs: publica no tópico sempre que a silver.ceasa_unificado é regravada com sucesso,
# seja na mão ou por um job, a partir do log de auditoria do BigQuery. Assim ninguém precisa
# mudar o código da ingestão para disparar a inferência.
COLETOR="mlops-silver-unificada-atualizada"
TABELA="projects/${PROJETO}/datasets/silver/tables/ceasa_unificado"
FILTRO="resource.type=\"bigquery_project\" \
AND logName=\"projects/${PROJETO}/logs/cloudaudit.googleapis.com%2Fdata_access\" \
AND protoPayload.metadata.jobChange.after=\"DONE\" \
AND (protoPayload.metadata.jobChange.job.jobConfig.queryConfig.destinationTable=\"${TABELA}\" \
OR protoPayload.metadata.jobChange.job.jobConfig.loadConfig.destinationTable=\"${TABELA}\") \
AND NOT protoPayload.metadata.jobChange.job.jobStatus.errorResult:*"
# A conta de serviço do Cloud Logging só existe depois de pedida (primeiro coletor do projeto)
gcloud beta services identity create --service=logging.googleapis.com --project "$PROJETO" >/dev/null
gcloud logging sinks describe "$COLETOR" --project "$PROJETO" >/dev/null 2>&1 ||
    gcloud logging sinks create "$COLETOR" "pubsub.googleapis.com/projects/${PROJETO}/topics/${TOPICO}" \
        --project "$PROJETO" --log-filter "$FILTRO" \
        --description "Publica em ${TOPICO} quando a silver.ceasa_unificado é regravada (inferência diária do MLOps)"
ESCRITOR="$(gcloud logging sinks describe "$COLETOR" --project "$PROJETO" --format 'value(writerIdentity)')"
gcloud pubsub topics add-iam-policy-binding "$TOPICO" --project "$PROJETO" \
    --member "$ESCRITOR" --role roles/pubsub.publisher --format none

# Workflow e gatilho
gcloud workflows deploy "$WORKFLOW" --location "$REGIAO" --project "$PROJETO" \
    --source "$PASTA/inferencia_diaria.workflow.yaml" --service-account "$CONTA"
gcloud eventarc triggers describe "$WORKFLOW" --location "$REGIAO" --project "$PROJETO" >/dev/null 2>&1 ||
    gcloud eventarc triggers create "$WORKFLOW" --location "$REGIAO" --project "$PROJETO" \
        --destination-workflow "$WORKFLOW" --destination-workflow-location "$REGIAO" \
        --event-filters "type=google.cloud.pubsub.topic.v1.messagePublished" \
        --transport-topic "projects/$PROJETO/topics/$TOPICO" --service-account "$CONTA"

# A assinatura que o Eventarc criou manda para a DLQ o que falhar 5 vezes
ASSINATURA="$(gcloud eventarc triggers describe "$WORKFLOW" --location "$REGIAO" --project "$PROJETO" \
    --format 'value(transport.pubsub.subscription)')"
NUMERO="$(gcloud projects describe "$PROJETO" --format 'value(projectNumber)')"
AGENTE_PUBSUB="service-${NUMERO}@gcp-sa-pubsub.iam.gserviceaccount.com"
gcloud pubsub subscriptions update "$ASSINATURA" --project "$PROJETO" \
    --dead-letter-topic "$DLQ" --max-delivery-attempts 5
gcloud pubsub topics add-iam-policy-binding "$DLQ" --project "$PROJETO" \
    --member "serviceAccount:$AGENTE_PUBSUB" --role roles/pubsub.publisher --format none
gcloud pubsub subscriptions add-iam-policy-binding "$ASSINATURA" --project "$PROJETO" \
    --member "serviceAccount:$AGENTE_PUBSUB" --role roles/pubsub.subscriber --format none

echo "Pronto. Teste publicando um aviso:"
echo "  gcloud pubsub topics publish $TOPICO --project $PROJETO --message '{\"origem\":\"teste\"}'"
