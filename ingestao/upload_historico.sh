#!/usr/bin/env bash
# Sobe o CSV histórico de cotações para o bucket do projeto.
# Reexecutar este script sobrescreve o mesmo objeto (não cria duplicata).
set -euo pipefail

# --- Variáveis (únicas fontes dos caminhos/nomes usados abaixo) ---
ARQUIVO_ORIGEM="/home/dos-anjos/Dropbox/PDM/historico/cotacoes_historico.csv"
BUCKET="gs://pdm-ceasa-dados"
PREFIXO_DESTINO="raw"
NOME_OBJETO="cotacoes_historico.csv"
PROJETO_GCP="pdm-ceasa"

DESTINO="${BUCKET}/${PREFIXO_DESTINO}/${NOME_OBJETO}"

# Aborta se o arquivo de origem não existir.
if [[ ! -f "${ARQUIVO_ORIGEM}" ]]; then
    echo "ERRO: arquivo de origem não encontrado: ${ARQUIVO_ORIGEM}" >&2
    exit 1
fi

# Upload idempotente: caminho de destino fixo, sobrescreve o objeto existente.
if ! gcloud storage cp "${ARQUIVO_ORIGEM}" "${DESTINO}" --project="${PROJETO_GCP}"; then
    echo "ERRO: falha no upload para ${DESTINO}" >&2
    exit 1
fi

echo "OK: ${ARQUIVO_ORIGEM} enviado para ${DESTINO}"
