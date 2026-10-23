# Imagem do Cloud Run Job atualizar-prata-ouro-diario (pipelines/atualizar_prata_ouro.sh).
# Contexto de build = raiz do repositorio (precisa de sql/); ver pipelines/cloudbuild.yaml.
# Base com gcloud + bq + python3; no Cloud Run o bq usa a conta de servico do job.
FROM gcr.io/google.com/cloudsdktool/google-cloud-cli:589.0.0-slim

WORKDIR /app
COPY sql/ sql/
COPY pipelines/atualizar_prata_ouro.sh pipelines/

# saida sem buffer: cada linha de log chega ao Cloud Logging na hora
ENV PYTHONUNBUFFERED=1
CMD ["bash", "pipelines/atualizar_prata_ouro.sh"]
