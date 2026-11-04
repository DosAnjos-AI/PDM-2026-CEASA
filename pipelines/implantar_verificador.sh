#!/usr/bin/env bash
# Implanta o Workflow verificar-e-atualizar-prata-ouro.
#
# O YAML do repositorio tem o marcador __SQL_DEFASAGEM__ no lugar do texto da
# consulta; aqui ele e trocado pelo conteudo do .sql antes do deploy. Assim a
# consulta tem uma fonte so (o .sql), como na imagem, que copia sql/ no build.
# Mudou a consulta 25_? Reimplante.
#
# Falha ruidosa: arquivo ausente ou marcador encontrado 0 ou 2+ vezes aborta
# antes do deploy.
# Requer bash + gcloud + python3 (Linux; no Windows, via WSL ou Git Bash).
#
# Uso (a partir de qualquer diretorio):
#   pipelines/implantar_verificador.sh
set -euo pipefail

# --- Variaveis ---
PROJETO="${PROJETO:-pdm-ceasa}"
REGIAO="${REGIAO:-us-central1}"
WORKFLOW="verificar-e-atualizar-prata-ouro"
SA="prata-ouro-evento@${PROJETO}.iam.gserviceaccount.com"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ_REPO="${RAIZ_REPO:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
ARQUIVO_WORKFLOW="${RAIZ_REPO}/pipelines/verificar_e_atualizar_prata_ouro.yaml"
ARQUIVO_SQL="${ARQUIVO_SQL:-${RAIZ_REPO}/sql/consultas/silver/25_defasagem_cadeia_check.sql}"

for arquivo in "${ARQUIVO_WORKFLOW}" "${ARQUIVO_SQL}"; do
    [[ -f "${arquivo}" ]] || { echo "ERRO: arquivo nao encontrado: ${arquivo}" >&2; exit 1; }
done

GERADO="$(mktemp "${TMPDIR:-/tmp}/verificador.XXXXXX.yaml")"
trap 'rm -f "${GERADO}"' EXIT

# O SQL entra como string JSON, que e uma string YAML valida entre aspas
# duplas: quebras de linha, aspas e crases ficam escapadas.
python3 - "${ARQUIVO_WORKFLOW}" "${ARQUIVO_SQL}" "${GERADO}" <<'PY'
import json, sys
from pathlib import Path
modelo, sql, destino = (Path(p) for p in sys.argv[1:4])
texto = modelo.read_text(encoding="utf-8")
alvo = "sql_defasagem: __SQL_DEFASAGEM__"
n = texto.count(alvo)
if n != 1:
    sys.exit(f"ERRO: marcador '{alvo}' encontrado {n} vezes em {modelo}; esperado 1")
destino.write_text(texto.replace(alvo, "sql_defasagem: " + json.dumps(sql.read_text(encoding="utf-8"), ensure_ascii=False)), encoding="utf-8")
PY

gcloud workflows deploy "${WORKFLOW}" --project="${PROJETO}" --location="${REGIAO}" \
    --source="${GERADO}" --service-account="${SA}" \
    --description="Le a defasagem da cadeia e roda atualizar-prata-ouro-evento so com os estados atrasados" \
    --format='value(name,revisionId)'
echo "ok: ${WORKFLOW} implantado com $(basename "${ARQUIVO_SQL}")"
