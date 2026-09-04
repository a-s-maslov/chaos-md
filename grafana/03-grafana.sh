#!/usr/bin/env bash
# 03 — Установка Grafana в Docker на ${MON_HOST} с примонтированным provisioning.
#
# Что делает:
#   1. Создаёт ${GRAFANA_DATA_DIR} и chown grafana (uid 472 в стандартном образе).
#   2. Запускает контейнер ${GRAFANA_DOCKER_IMAGE} с маунтами:
#        ${GRAFANA_DATA_DIR}                    → /var/lib/grafana
#        <repo>/grafana/provisioning            → /etc/grafana/provisioning:ro
#        <repo>/grafana/dashboards              → /var/lib/grafana/dashboards:ro
#      и --network host (чтобы достучаться до VictoriaMetrics на :${VM_PORT}).
#   3. Печатает URL и подсказку про SSH-туннель из дома.
#
# Provisioning (datasource VictoriaMetrics + dashboard provider) надо подготовить
# до этого скрипта: запустите 04-dashboards-provision.sh заранее или после.
# Если 04 ещё не запущен — Grafana стартует, но без datasource. Затем 04 и rebar.
#
# Запускать НА ${MON_HOST}.
#
# Опции:
#   --check     Показать статус контейнера и проверить http://localhost:${GRAFANA_PORT}/login
#   --replace   Удалить существующий контейнер grafana перед запуском.
#   --dry-run   Печатать команды, не выполнять
#   -h, --help  Справка
#
# Переменная для admin пароля (env.local.sh): GRAFANA_ADMIN_PASSWORD (дефолт: admin).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${REPO_DIR}/lib/config.sh"
chaos_load_env "${REPO_DIR}"
# shellcheck source=../lib/term.sh
source "${REPO_DIR}/lib/term.sh"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/grafana-03-grafana.log"
# shellcheck source=../lib/log.sh
source "${REPO_DIR}/lib/log.sh"

MODE_CHECK=false
MODE_REPLACE=false
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-false}"

usage() {
    cat <<EOF
$(basename "$0") — install Grafana in docker on ${MON_HOST}.

  --check       Показать статус контейнера и доступность UI
  --replace     Явно заменить существующий контейнер grafana
  --dry-run     Печатать команды, не выполнять
  -h, --help    Справка

Конфигурация (env.sh):
  GRAFANA_DOCKER_IMAGE=${GRAFANA_DOCKER_IMAGE}
  GRAFANA_DATA_DIR=${GRAFANA_DATA_DIR}
  GRAFANA_PORT=${GRAFANA_PORT}
  Provisioning: ${SCRIPT_DIR}/provisioning
  Dashboards:   ${SCRIPT_DIR}/dashboards
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

export GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"

if [[ "${MODE_CHECK}" == "true" ]]; then
    log_section "Проверка Grafana на ${MON_HOST}"
    run_cmd "docker ps --filter name=^grafana$ --format '{{.Names}}\t{{.Status}}\t{{.Ports}}'"
    run_cmd "curl -sf -o /dev/null -w 'http %{http_code}\n' http://localhost:${GRAFANA_PORT}/login || echo 'login=FAIL'"
    exit 0
fi

log_section "Установка Grafana на ${MON_HOST}"
log "Образ: ${GRAFANA_DOCKER_IMAGE}, port: ${GRAFANA_PORT}"

PROV_DIR="${SCRIPT_DIR}/provisioning"
DASH_DIR="${SCRIPT_DIR}/dashboards"

if [[ ! -d "${PROV_DIR}/datasources" ]]; then
    log "ПРЕДУПРЕЖДЕНИЕ: ${PROV_DIR}/datasources не найден — запустите 04-dashboards-provision.sh для генерации."
fi

# Каталог данных и владелец (uid 472 в стандартном образе grafana).
run_cmd "sudo mkdir -p ${GRAFANA_DATA_DIR}"
run_cmd "sudo chown -R 472:472 ${GRAFANA_DATA_DIR}"

# По умолчанию не трогаем существующий контейнер с таким именем.
if [[ "${CHAOS_DRY_RUN}" != "true" ]] && docker container inspect grafana >/dev/null 2>&1; then
    if [[ "${MODE_REPLACE}" != "true" ]]; then
        log "ОШИБКА: контейнер grafana уже существует. Проверьте его или повторите с --replace."
        exit 1
    fi
    run_cmd "docker rm -f grafana"
fi
run_cmd "docker run -d --name grafana --restart unless-stopped \
    --network host \
    -e GF_SECURITY_ADMIN_PASSWORD \
    -e GF_SERVER_HTTP_PORT='${GRAFANA_PORT}' \
    -v ${GRAFANA_DATA_DIR}:/var/lib/grafana \
    -v ${PROV_DIR}:/etc/grafana/provisioning:ro \
    -v ${DASH_DIR}:/var/lib/grafana/dashboards:ro \
    ${GRAFANA_DOCKER_IMAGE}"

if [[ "${CHAOS_DRY_RUN}" != "true" ]]; then
    sleep 3
    if curl -sf -o /dev/null "http://localhost:${GRAFANA_PORT}/login"; then
        log "✓ Grafana доступна на http://${MON_HOST}:${GRAFANA_PORT}/ (user: admin; пароль из env.local.sh)"
    else
        log "ПРЕДУПРЕЖДЕНИЕ: /login пока недоступен. docker logs grafana"
    fi
fi

cat <<EOF

Чтобы открыть UI снаружи лаба, проброс порта:
  ssh -L ${GRAFANA_PORT}:localhost:${GRAFANA_PORT} ${MON_HOST}
И затем http://localhost:${GRAFANA_PORT}/

EOF

log_section "Готово"
