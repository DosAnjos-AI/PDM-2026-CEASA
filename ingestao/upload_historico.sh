#!/usr/bin/env bash
# Sobe o CSV histórico de cotações para o bucket do projeto.
# Reexecutar este script sobrescreve o mesmo objeto (não cria duplicata).
set -euo pipefail

# --- Variáveis (únicas fontes dos caminhos/nomes usados abaixo) ---
BUCKET="gs://pdm-ceasa-dados"
PREFIXO_DESTINO="raw"
NOME_OBJETO="cotacoes_historico.csv"
PROJETO_GCP="pdm-ceasa"

# Raiz do repositório resolvida a partir da localização do script (não do diretório de chamada).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ_REPO="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ARQUIVO_ORIGEM tem precedência se definida no ambiente; caso contrário usa o default,
# relativo à raiz do repositório (o CSV histórico fica fora do repositório e do versionamento).
ARQUIVO_ORIGEM="${ARQUIVO_ORIGEM:-${RAIZ_REPO}/../historico/cotacoes_historico.csv}"

DESTINO="${BUCKET}/${PREFIXO_DESTINO}/${NOME_OBJETO}"

# Aborta se o arquivo de origem não existir.
if [[ ! -f "${ARQUIVO_ORIGEM}" ]]; then
    echo "ERRO: arquivo de origem não encontrado: ${ARQUIVO_ORIGEM}" >&2
    echo "Defina a variável de ambiente ARQUIVO_ORIGEM com o caminho correto." >&2
    exit 1
fi

# Upload idempotente: caminho de destino fixo, sobrescreve o objeto existente.
if ! gcloud storage cp "${ARQUIVO_ORIGEM}" "${DESTINO}" --project="${PROJETO_GCP}"; then
    echo "ERRO: falha no upload para ${DESTINO}" >&2
    exit 1
fi

echo "OK: ${ARQUIVO_ORIGEM} enviado para ${DESTINO}"
