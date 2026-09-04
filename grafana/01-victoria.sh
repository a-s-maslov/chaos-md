#!/usr/bin/env bash
# 01 — Установка VictoriaMetrics (single-binary) в Docker на ${MON_HOST}.
#
# Что делает:
#   1. Создаёт каталоги данных и конфигов.
#   2. Копирует статический grafana/scrape.yml в VM_CONFIG_DIR
#      и генерирует file_sd-файлы таргетов в VM_TARGETS_DIR.
#   3. Запускает контейнер ${VICTORIA_DOCKER_IMAGE} с --network host.
#
# Запускать НА ${MON_HOST} ${MON_HOST}. FQDN рабочих хостов резолвятся внутри лаба.
#
# Опции:
#   --check     Показать состояние контейнера и доступность ${VM_PORT}.
#   --replace   Удалить существующий контейнер vm перед запуском.
#   --dry-run   Печатать команды, не выполнять.
#   -h, --help  Эта справка.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${REPO_DIR}/lib/config.sh"
chaos_load_env "${REPO_DIR}"

# shellcheck source=../lib/term.sh
source "${REPO_DIR}/lib/term.sh"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/grafana-01-victoria.log"
# shellcheck source=../lib/log.sh
source "${REPO_DIR}/lib/log.sh"

MODE_CHECK=false
MODE_REPLACE=false
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-false}"

TARGETS_DIR="${VM_TARGETS_DIR:-${VM_FILE_SD_DIR:-/etc/prometheus}}"
VM_CFG_DIR="${VM_CONFIG_DIR:-/etc/victoriametrics}"
SCRAPE_CFG="${VM_CFG_DIR}/scrape.yml"
SCRAPE_SRC="${SCRIPT_DIR}/scrape.yml"

usage() {
    cat <<EOF
$(basename "$0") — install VictoriaMetrics (single) on ${MON_HOST}.

  --check       Показать статус контейнера и доступность http://localhost:${VM_PORT}/-/ready
  --replace     Явно заменить существующий контейнер vm
  --dry-run     Печатать команды, не выполнять
  -h, --help    Справка

Конфигурация (env.sh):
  MON_HOST=${MON_HOST}
  VICTORIA_DOCKER_IMAGE=${VICTORIA_DOCKER_IMAGE}
  VM_DATA_DIR=${VM_DATA_DIR}
  VM_CONFIG_DIR=${VM_CFG_DIR}
  VM_TARGETS_DIR=${TARGETS_DIR}
  VM_PORT=${VM_PORT}
  VM_RETENTION=${VM_RETENTION}
  VM_LATENCY_OFFSET=${VM_LATENCY_OFFSET:-0s}
  Cluster hosts (${#CLUSTER_HOSTS[@]}): ${CLUSTER_HOSTS[*]}
    YDB_MON_PORTS:   ${YDB_MON_PORTS}
    YDB_MON_PD_PORT: ${YDB_MON_PD_PORT} (порт мониторинга узла хранения, pdisks/vdisks)
    node_exporter:   ${NODE_EXPORTER_PORT}
    workload:        ${WORKLOAD_METRICS_TARGET:-127.0.0.1:9091}
    observer:        ${OBSERVER_METRICS_TARGET:-127.0.0.1:9092}
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    MODE_CHECK=true; shift ;;
        --replace)  MODE_REPLACE=true; shift ;;
        --dry-run)  CHAOS_DRY_RUN=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 1 ;;
    esac
done

run_cmd() {
    chaos_term_remote_cmd "$*"
    if [[ "${CHAOS_DRY_RUN}" == "true" ]]; then
        return 0
    fi
    eval "$@"
}

if [[ "${MODE_CHECK}" == "true" ]]; then
    log_section "Проверка VictoriaMetrics на ${MON_HOST}"
    run_cmd "docker ps --filter name=^vm$ --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'"
    run_cmd "curl -sf http://localhost:${VM_PORT}/-/ready && echo '  ready=ok' || echo '  ready=FAIL'"
    if [[ "${CHAOS_DRY_RUN}" == "true" ]]; then
        chaos_term_remote_cmd "curl -sf http://localhost:${VM_PORT}/api/v1/targets  # summarize up/down targets"
    else
        curl -sf "http://localhost:${VM_PORT}/api/v1/targets" | python3 -c '
import collections
import json
import sys

targets = json.load(sys.stdin)["data"]["activeTargets"]
counts = collections.Counter(
    (target.get("labels", {}).get("job", "?"), target.get("health", "?"))
    for target in targets
)
print(f"  targets={len(targets)}")
for (job, health), count in sorted(counts.items()):
    print(f"  {job}: {health}={count}")
'
    fi
    exit 0
fi

log_section "Установка VictoriaMetrics на ${MON_HOST}"
log "Образ: ${VICTORIA_DOCKER_IMAGE}, retention: ${VM_RETENTION}, port: ${VM_PORT}"
log "Хосты (${#CLUSTER_HOSTS[@]}): ${CLUSTER_HOSTS[*]}"
log "YDB mon: YDB_MON_PORTS=${YDB_MON_PORTS}, pdisks/vdisks: YDB_MON_PD_PORT=${YDB_MON_PD_PORT}"

# Сгенерировать файл таргетов в формате file_sd_configs (одна группа).
build_targets_yml() {
    local port="$1" container_label="$2"
    echo "- targets:"
    local h
    for h in "${CLUSTER_HOSTS[@]}"; do
        printf '    - %s:%s\n' "${h}" "${port}"
    done
    cat <<EOF
  labels:
    container: ${container_label}
    database: ${YDB_DATABASE:-/Root/db1}
EOF
}

# Несколько групп: каждый порт из YDB_MON_PORTS × все хосты (см. grafana/scrape.yml → ydbd-mon.yml).
build_ydbd_mon_yml() {
    local p h container raw
    local -a _ports_arr=()
    IFS=',' read -ra _ports_arr <<< "${YDB_MON_PORTS// /}"
    for raw in "${_ports_arr[@]}"; do
        p="${raw// /}"
        [[ -z "${p}" ]] && continue
        if [[ "${p}" == "8765" ]]; then
            container="ydb-static"
        else
            container="ydb-dynamic"
        fi
        echo "- targets:"
        for h in "${CLUSTER_HOSTS[@]}"; do
            printf '    - %s:%s\n' "${h}" "${p}"
        done
        cat <<EOF
  labels:
    container: ${container}
    mon_port: "${p}"
    database: ${YDB_DATABASE:-/Root/db1}
EOF
    done
}

# Только YDB_MON_PD_PORT (порт мониторинга узла хранения) — job'ы pdisks/vdisks в scrape.yml.
build_ydbd_pd_yml() {
    local port="${YDB_MON_PD_PORT}" h
    echo "- targets:"
    for h in "${CLUSTER_HOSTS[@]}"; do
        printf '    - %s:%s\n' "${h}" "${port}"
    done
    cat <<EOF
  labels:
    container: ydb-static
    mon_port: "${port}"
    database: ${YDB_DATABASE:-/Root/db1}
EOF
}

build_workload_yml() {
    cat <<EOF
- targets:
    - ${WORKLOAD_METRICS_TARGET:-127.0.0.1:9091}
  labels:
    component: deep-tech-ydb-searches
EOF
}

build_observer_yml() {
    cat <<EOF
- targets:
    - ${OBSERVER_METRICS_TARGET:-127.0.0.1:9092}
  labels:
    component: ydb-partition-observer
EOF
}

ensure_dir() {
    if mkdir -p "$@" 2>/dev/null; then
        return 0
    fi
    sudo mkdir -p "$@"
}

copy_file() {
    local source="$1" destination="$2"
    if cp "${source}" "${destination}" 2>/dev/null; then
        return 0
    fi
    sudo cp "${source}" "${destination}"
}

write_generated_file() {
    local destination="$1"
    if [[ -w "$(dirname "${destination}")" ]]; then
        tee "${destination}" >/dev/null
    else
        sudo tee "${destination}" >/dev/null
    fi
}

if [[ "${CHAOS_DRY_RUN}" == "true" ]]; then
    chaos_term_remote_cmd "mkdir -p $(dirname "${SCRAPE_CFG}") ${TARGETS_DIR} ${VM_DATA_DIR}"
    log "  --- dry-run node-exporter.yml ---"
    build_targets_yml "${NODE_EXPORTER_PORT}" "node" | sed 's/^/  | /'
    log "  --- dry-run workload.yml ---"
    build_workload_yml | sed 's/^/  | /'
    log "  --- dry-run ydb-partition-observer.yml ---"
    build_observer_yml | sed 's/^/  | /'
    log "  --- dry-run ydbd-mon.yml ---"
    build_ydbd_mon_yml | sed 's/^/  | /'
    log "  --- dry-run ydbd-storage.yml (pdisks/vdisks, YDB_MON_PD_PORT=${YDB_MON_PD_PORT}) ---"
    build_ydbd_pd_yml | sed 's/^/  | /'
else
    ensure_dir "$(dirname "${SCRAPE_CFG}")" "${TARGETS_DIR}" "${VM_DATA_DIR}"

    copy_file "${SCRAPE_SRC}" "${SCRAPE_CFG}"
    log "  ${SCRAPE_CFG} скопирован из ${SCRAPE_SRC}"

    build_targets_yml "${NODE_EXPORTER_PORT}" "node" | write_generated_file "${TARGETS_DIR}/node-exporter.yml"
    build_workload_yml | write_generated_file "${TARGETS_DIR}/workload.yml"
    build_observer_yml | write_generated_file "${TARGETS_DIR}/ydb-partition-observer.yml"
    build_ydbd_mon_yml | write_generated_file "${TARGETS_DIR}/ydbd-mon.yml"
    build_ydbd_pd_yml  | write_generated_file "${TARGETS_DIR}/ydbd-storage.yml"
    log "  Файлы таргетов записаны в ${TARGETS_DIR}/ (workload: ${WORKLOAD_METRICS_TARGET:-127.0.0.1:9091}, observer: ${OBSERVER_METRICS_TARGET:-127.0.0.1:9092}, ydbd-mon.yml: ${YDB_MON_PORTS})"
fi

# --network host: доступ к node_exporter и ydb по FQDN из лаб-сети.
# TARGETS_DIR монтируется во внутренний путь file_sd_configs контейнера.
log "Запуск контейнера vm"
if [[ "${CHAOS_DRY_RUN}" != "true" ]] && docker container inspect vm >/dev/null 2>&1; then
    if [[ "${MODE_REPLACE}" != "true" ]]; then
        log "ОШИБКА: контейнер vm уже существует. Проверьте его или повторите с --replace."
        exit 1
    fi
    run_cmd "docker rm -f vm"
fi
run_cmd "docker run -d --name vm --restart unless-stopped \
    --network host \
    -v ${VM_DATA_DIR}:/victoria-metrics-data \
    -v ${SCRAPE_CFG}:/etc/scrape.yml:ro \
    -v ${TARGETS_DIR}:/etc/prometheus:ro \
    ${VICTORIA_DOCKER_IMAGE} \
    -storageDataPath=/victoria-metrics-data \
    -httpListenAddr=:${VM_PORT} \
    -retentionPeriod=${VM_RETENTION} \
    -search.latencyOffset=${VM_LATENCY_OFFSET:-0s} \
    -promscrape.config=/etc/scrape.yml"

if [[ "${CHAOS_DRY_RUN}" != "true" ]]; then
    sleep 2
    if curl -sf "http://localhost:${VM_PORT}/-/ready" >/dev/null; then
        log "✓ VictoriaMetrics готов на http://${MON_HOST}:${VM_PORT}"
    else
        log "ПРЕДУПРЕЖДЕНИЕ: /-/ready пока недоступен. Проверьте: docker logs vm"
    fi
fi

log_section "Готово"
