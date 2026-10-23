#!/usr/bin/env bash
# Reconstroi a cadeia prata/ouro do pipeline de 5 estados + clima, a partir
# da bronze (cotacoes do ciclo-ceasa e clima do clima-diario).
#
# Faz: roda os 8 scripts de sql/construir_tabelas/ na ordem de dependencia
# (clima -> 5 estados -> unificado -> gold) e, depois de cada um, a consulta
# de conferencia correspondente de sql/consultas/, logando o resultado.
# Os 5 estados rodam em sequencia (podiam ser paralelos; sequencial e mais
# simples e o tempo total e pequeno).
# Falha ruidosa: qualquer etapa (construcao ou conferencia) com erro aborta
# a cadeia com codigo 1 -- nenhuma etapa seguinte roda sobre dado
# incompleto/desatualizado. Logs em JSON com severity (Cloud Logging).
# Idempotente: cada script e CREATE OR REPLACE TABLE (rebuild total).
#
# Uso (a partir de qualquer diretorio):
#   pipelines/atualizar_prata_ouro.sh             # recria as 8 tabelas
#   pipelines/atualizar_prata_ouro.sh --simular   # construcao em dry_run, conferencias de verdade (so leitura)
set -euo pipefail

# --- Variaveis ---
PROJETO="${PROJETO:-pdm-ceasa}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ_REPO="${RAIZ_REPO:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
SIMULAR=false
[[ "${1:-}" == "--simular" ]] && SIMULAR=true

# construcao:conferencia, na ordem de execucao
ETAPAS=(
    "sql/construir_tabelas/silver/09_clima_historico_bronze_to_silver.sql:sql/consultas/silver/18_clima_historico_check.sql"
    "sql/construir_tabelas/silver/10_ceasa_go_prata.sql:sql/consultas/silver/19_ceasa_go_prata_check.sql"
    "sql/construir_tabelas/silver/11_ceasa_sc_prata.sql:sql/consultas/silver/20_ceasa_sc_prata_check.sql"
    "sql/construir_tabelas/silver/12_ceasa_ms_prata.sql:sql/consultas/silver/21_ceasa_ms_prata_check.sql"
    "sql/construir_tabelas/silver/13_ceasa_mg_prata.sql:sql/consultas/silver/22_ceasa_mg_prata_check.sql"
    "sql/construir_tabelas/silver/14_ceasa_es_prata.sql:sql/consultas/silver/23_ceasa_es_prata_check.sql"
    "sql/construir_tabelas/silver/15_ceasa_unificado.sql:sql/consultas/silver/24_ceasa_unificado_check.sql"
    "sql/construir_tabelas/gold/06_ceasa_unificado_semanal_quinzenal.sql:sql/consultas/gold/16_ceasa_unificado_semanal_quinzenal_check.sql"
)

# Uma linha JSON por log; o Cloud Logging le o campo severity.
log() {
    python3 -c 'import json, sys; print(json.dumps({"severity": sys.argv[1], "message": sys.argv[2]}, ensure_ascii=False), flush=True)' "$1" "$2"
}

falhar() {
    log ERROR "$1"
    exit 1
}

roda_sql() {
    bq --project_id="${PROJETO}" query --quiet --use_legacy_sql=false --format=pretty "${@:2}" < "${RAIZ_REPO}/$1" 2>&1
}

# Aborta antes de qualquer escrita se algum arquivo da cadeia faltar.
for etapa in "${ETAPAS[@]}"; do
    for arquivo in "${etapa%%:*}" "${etapa##*:}"; do
        [[ -f "${RAIZ_REPO}/${arquivo}" ]] || falhar "arquivo nao encontrado: ${RAIZ_REPO}/${arquivo}"
    done
done

log INFO "inicio: projeto=${PROJETO} etapas=${#ETAPAS[@]} simular=${SIMULAR}"
for etapa in "${ETAPAS[@]}"; do
    construcao="${etapa%%:*}"
    conferencia="${etapa##*:}"

    log INFO "construindo: ${construcao}"
    opcoes=()
    [[ "${SIMULAR}" == true ]] && opcoes=(--dry_run)
    if ! saida="$(roda_sql "${construcao}" "${opcoes[@]}")"; then
        falhar "falha em ${construcao}; cadeia interrompida: ${saida}"
    fi

    if ! saida="$(roda_sql "${conferencia}")"; then
        falhar "falha na conferencia ${conferencia}; cadeia interrompida: ${saida}"
    fi
    log INFO "conferencia ${conferencia}:
$(grep -E '^\|' <<< "${saida}" || true)"
done
log INFO "fim: ok nas ${#ETAPAS[@]} etapas"
