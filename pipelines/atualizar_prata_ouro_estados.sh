#!/usr/bin/env bash
# Reconstroi a prata dos estados pedidos e, em seguida, sempre o unificado e as
# 2 tabelas ouro. Existe ao lado de pipelines/atualizar_prata_ouro.sh (plano B
# das 16:30), que nao muda: o plano B reconstroi tudo, este so o necessario.
#
# Ordem fixa: 1x_ dos estados pedidos -> 15_ unificado -> 06_ ouro. O unificado
# le as 5 pratas e o ouro le o unificado; qualquer outra ordem publicaria
# unificado ou ouro sobre prata velha.
# O clima (09_) fica de fora: silver.clima_historico e do plano B.
# Bronze: somente leitura. Nenhum SQL desta cadeia escreve nela.
#
# Falha ruidosa: estado fora da lista, chamada sem estado, arquivo ausente ou
# erro em qualquer etapa abortam com codigo 1. Validacao inteira antes da
# primeira escrita, para nunca deixar a cadeia pela metade por erro de chamada.
# No fim, a consulta de defasagem (25_) tem de mostrar unificado e ouro em dia.
# Idempotente: todo SQL e CREATE OR REPLACE TABLE (rebuild total).
# Requer bash + bq + python3 (Linux; no Windows, via WSL ou Git Bash).
#
# Uso (a partir de qualquer diretorio):
#   pipelines/atualizar_prata_ouro_estados.sh es              # reconstroi ES, unificado, ouro
#   pipelines/atualizar_prata_ouro_estados.sh go sc           # GO e SC, depois unificado e ouro
#   pipelines/atualizar_prata_ouro_estados.sh --simular es    # so imprime o plano, nao executa nada
set -euo pipefail

# --- Variaveis ---
PROJETO="${PROJETO:-pdm-ceasa}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ_REPO="${RAIZ_REPO:-$(cd "${SCRIPT_DIR}/.." && pwd)}"

# Lista fechada de estados aceitos (uf:construcao:conferencia). Estado novo
# entra aqui, e so aqui; a ordem desta lista e a ordem de execucao.
ESTADOS=(
    "go:sql/construir_tabelas/silver/10_ceasa_go_prata.sql:sql/consultas/silver/19_ceasa_go_prata_check.sql"
    "sc:sql/construir_tabelas/silver/11_ceasa_sc_prata.sql:sql/consultas/silver/20_ceasa_sc_prata_check.sql"
    "ms:sql/construir_tabelas/silver/12_ceasa_ms_prata.sql:sql/consultas/silver/21_ceasa_ms_prata_check.sql"
    "mg:sql/construir_tabelas/silver/13_ceasa_mg_prata.sql:sql/consultas/silver/22_ceasa_mg_prata_check.sql"
    "es:sql/construir_tabelas/silver/14_ceasa_es_prata.sql:sql/consultas/silver/23_ceasa_es_prata_check.sql"
)
# Etapas que rodam sempre depois das pratas, nesta ordem.
FINAIS=(
    "sql/construir_tabelas/silver/15_ceasa_unificado.sql:sql/consultas/silver/24_ceasa_unificado_check.sql"
    "sql/construir_tabelas/gold/06_ceasa_unificado_semanal_quinzenal.sql:sql/consultas/gold/16_ceasa_unificado_semanal_quinzenal_check.sql"
)
DEFASAGEM="sql/consultas/silver/25_defasagem_cadeia_check.sql"
# Repeticoes depois da passada pedida. 3 porque uma rajada do ciclo-ceasa
# dura ~45 s e cada passada leva 1-3 min: a 1a repeticao ja cobre o que foi
# escrito durante a passada original, e o limite mantem o pior caso
# (~4 passadas, ~12 min) bem abaixo do timeout do job (1800 s).
MAX_REPETICOES=3

# Uma linha JSON por log, no mesmo formato do plano B.
log() {
    python3 -c 'import json, sys; print(json.dumps({"severity": sys.argv[1], "message": sys.argv[2]}, ensure_ascii=False), flush=True)' "$1" "$2"
}

falhar() {
    log ERROR "$1"
    exit 1
}

roda_sql() {
    bq --project_id="${PROJETO}" query --quiet --use_legacy_sql=false --format="$2" < "${RAIZ_REPO}/$1" 2>&1
}

# --- Argumentos ---
SIMULAR=false
PEDIDOS=()
for arg in "$@"; do
    case "${arg}" in
        --simular) SIMULAR=true ;;
        *) PEDIDOS+=("${arg}") ;;
    esac
done

aceitos=""
for item in "${ESTADOS[@]}"; do aceitos+="${item%%:*} "; done

# Sem padrao de proposito: um padrao errado reconstruiria a coisa errada
# sem ninguem perceber.
(( ${#PEDIDOS[@]} > 0 )) || falhar "nenhum estado informado; aceitos: ${aceitos% }; lista em ESTADOS no topo de ${BASH_SOURCE[0]}"

for pedido in "${PEDIDOS[@]}"; do
    [[ " ${aceitos}" == *" ${pedido} "* ]] || \
        falhar "estado invalido: '${pedido}'; aceitos: ${aceitos% }; lista em ESTADOS no topo de ${BASH_SOURCE[0]}"
done

# Monta ETAPAS para os estados recebidos, na ordem da lista fechada (nao na
# ordem digitada), sem repetir estado, e aborta antes de qualquer escrita se
# algum arquivo faltar: pular uma etapa publicaria unificado ou ouro sobre
# prata desatualizada.
montar_etapas() {
    ETAPAS=()
    local item uf pedido etapa arquivo
    for item in "${ESTADOS[@]}"; do
        uf="${item%%:*}"
        for pedido in "$@"; do
            if [[ "${pedido}" == "${uf}" ]]; then
                ETAPAS+=("${item#*:}")
                break
            fi
        done
    done
    ETAPAS+=("${FINAIS[@]}")
    for etapa in "${ETAPAS[@]}"; do
        for arquivo in "${etapa%%:*}" "${etapa##*:}"; do
            [[ -f "${RAIZ_REPO}/${arquivo}" ]] || falhar "arquivo nao encontrado: ${RAIZ_REPO}/${arquivo}"
        done
    done
}

rodar_etapas() {
    local etapa construcao conferencia saida
    for etapa in "${ETAPAS[@]}"; do
        construcao="${etapa%%:*}"
        conferencia="${etapa##*:}"

        log INFO "construindo: ${construcao}"
        if ! saida="$(roda_sql "${construcao}" pretty)"; then
            falhar "falha em ${construcao}; cadeia interrompida: ${saida}"
        fi

        if ! saida="$(roda_sql "${conferencia}" pretty)"; then
            falhar "falha na conferencia ${conferencia}; cadeia interrompida: ${saida}"
        fi
        log INFO "conferencia ${conferencia}:
$(grep -E '^\|' <<< "${saida}" || true)"
    done
}

# Defasagem: a consulta devolve sempre uma linha 'resumo' com as contagens
# (estado, unificado, gold). Sem ela, a consulta esta quebrada -- nunca se
# conclui "em dia" por ausencia de saida. Preenche n_estado, n_unificado,
# n_gold, detalhe e ATRASADOS (ufs com regra 'estado').
ler_defasagem() {
    local saida resumo n linha uf
    if ! saida="$(roda_sql "${DEFASAGEM}" csv)"; then
        falhar "falha na consulta de defasagem ${DEFASAGEM}: ${saida}"
    fi
    resumo="$(grep -m1 '^resumo,' <<< "${saida}" || true)"
    [[ -n "${resumo}" ]] || falhar "linha de resumo ausente na consulta de defasagem ${DEFASAGEM}; esperado 'resumo,,,,,<estado>,<unificado>,<gold>'; saida: ${saida}"
    IFS=, read -r _ _ _ _ _ n_estado n_unificado n_gold <<< "${resumo}"
    for n in "${n_estado}" "${n_unificado}" "${n_gold}"; do
        [[ "${n}" =~ ^[0-9]+$ ]] || falhar "linha de resumo malformada na consulta de defasagem: '${resumo}'"
    done
    detalhe="$(grep -E '^(estado|unificado|gold),' <<< "${saida}" || true)"
    ATRASADOS=()
    while IFS=, read -r _ linha _; do
        [[ -n "${linha}" ]] || continue
        uf="${linha#silver.ceasa_}"
        [[ " ${aceitos}" == *" ${uf} "* ]] || falhar "defasagem devolveu estado fora da lista fechada: '${linha}'"
        ATRASADOS+=("${uf}")
    done < <(grep -E '^estado,' <<< "${saida}" || true)
    (( ${#ATRASADOS[@]} == n_estado )) || falhar "defasagem: ${#ATRASADOS[@]} linhas de estado, resumo diz ${n_estado}"
}

montar_etapas "${PEDIDOS[@]}"
[[ -f "${RAIZ_REPO}/${DEFASAGEM}" ]] || falhar "arquivo nao encontrado: ${RAIZ_REPO}/${DEFASAGEM}"

if [[ "${SIMULAR}" == true ]]; then
    # Simular nao chama o BigQuery: so mostra o que seria executado.
    n=0
    for etapa in "${ETAPAS[@]}"; do
        n=$((n + 1))
        echo "etapa ${n}: ${etapa%%:*} (conferencia: ${etapa##*:})"
    done
    echo "defasagem: ${DEFASAGEM}"
    exit 0
fi

log INFO "inicio: projeto=${PROJETO} estados=${PEDIDOS[*]} etapas=${#ETAPAS[@]}"

# Por que repetir: numa rajada (o ciclo-ceasa escreve os estados em sequencia,
# ~45 s), o 1o disparo chama este job com os estados ja atrasados naquele
# instante, e os disparos seguintes saem do Workflow por "execucao em curso".
# Sem reavaliar aqui, o que chegou durante a passada ficava para tras ate o
# plano B das 16:30, em silencio. Ensaio de 04/11: 5 escritas em ~7 s, job
# com go;ms;sc, MG e ES esquecidos. Nao remover sem resolver isso em outro
# lugar. A repeticao roda so os estados ainda atrasados, e sempre seguidos de
# unificado e ouro.
repeticao=0
while true; do
    rodar_etapas
    ler_defasagem
    # Unificado ou ouro atrasado depois de uma passada completa e falha: os
    # modelos leem essas tabelas, e a passada acabou de reconstrui-las.
    if (( n_unificado + n_gold > 0 )); then
        falhar "defasagem: unificado ou ouro atras da prata depois da cadeia (unificado=${n_unificado} gold=${n_gold}):
${detalhe}"
    fi
    (( n_estado == 0 )) && break
    # Sobra no limite e ERROR, nunca WARNING: e exatamente o defeito que a
    # repeticao existe para eliminar, e tem de acender o alerta.
    if (( repeticao >= MAX_REPETICOES )); then
        falhar "defasagem: ${n_estado} estado(s) ainda atrasado(s) depois de ${MAX_REPETICOES} repeticoes:
${detalhe}"
    fi
    repeticao=$((repeticao + 1))
    log WARNING "repeticao ${repeticao}/${MAX_REPETICOES}: estados atrasados durante a passada anterior: ${ATRASADOS[*]}"
    montar_etapas "${ATRASADOS[@]}"
done
log INFO "fim: ok; repeticoes=${repeticao}; unificado e ouro em dia"
