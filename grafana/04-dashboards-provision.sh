#!/usr/bin/env bash
# 04 — Подготовка provisioning-конфигов Grafana из шаблонов с подстановкой
# параметров стенда (VM_PORT и др.). Перезагружает provisioning у запущенного
# контейнера grafana, если он есть.
#
# Что делает:
#   1. Рендерит provisioning/datasources/victoriametrics.yml.tmpl
#      → provisioning/datasources/victoriametrics.yml (с VM_PORT из env.sh).
#   2. Provisioning/dashboards/dashboards.yml — статичный, проверяется наличие.
#   3. Если контейнер grafana запущен — `docker restart grafana`, чтобы Grafana
#      перечитала provisioning. Дашборды в grafana/dashboards/*.json подхватятся
#      автоматически благодаря file-provider (см. dashboards.yml).
#
# Запускать НА ${MON_HOST} ПОСЛЕ 03-grafana.sh (или до — тогда конфиги будут
# готовы к моменту первого старта Grafana).
#
# Опции:
#   --check     Показать содержимое сгенерированных yml.
#   --dry-run   Печатать команды, не выполнять (но рендер шаблонов проходит).
#   -h, --help  Справка.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${REPO_DIR}/lib/config.sh"
chaos_load_env "${REPO_DIR}"
# shellcheck source=../lib/term.sh
source "${REPO_DIR}/lib/term.sh"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/grafana-04-dashboards-provision.log"
# shellcheck source=../lib/log.sh
source "${REPO_DIR}/lib/log.sh"

MODE_CHECK=false
CHAOS_DRY_RUN="${CHAOS_DRY_RUN:-false}"

usage() {
    cat <<EOF
$(basename "$0") — render provisioning configs and reload grafana.

  --check       Показать сгенерированные provisioning файлы и список dashboards
  --dry-run     Печатать команды, не перезапускать контейнер
  -h, --help    Справка

Конфигурация (env.sh):
  VM_PORT=${VM_PORT}
  Templates: ${SCRIPT_DIR}/provisioning/datasources/*.tmpl
  Dashboards: ${SCRIPT_DIR}/dashboards/*.json
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)    MODE_CHECK=true; shift ;;
        --dry-run)  CHAOS_DRY_RUN=true; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 1 ;;
    esac
done

DS_TMPL="${SCRIPT_DIR}/provisioning/datasources/victoriametrics.yml.tmpl"
DS_OUT="${SCRIPT_DIR}/provisioning/datasources/victoriametrics.yml"
DASH_PROV="${SCRIPT_DIR}/provisioning/dashboards/dashboards.yml"

if [[ "${MODE_CHECK}" == "true" ]]; then
    log_section "Provisioning файлы"
    for f in "${DS_OUT}" "${DASH_PROV}"; do
        echo "--- ${f}"
        if [[ -f "${f}" ]]; then
            cat "${f}"
        else
            echo "  (отсутствует)"
        fi
        echo ""
    done
    log_section "Dashboards"
    ls -la "${SCRIPT_DIR}/dashboards/"*.json 2>/dev/null || echo "  нет .json"
    exit 0
fi

log_section "Render provisioning"

if [[ ! -f "${DS_TMPL}" ]]; then
    echo "Ошибка: шаблон не найден: ${DS_TMPL}" >&2
    exit 1
fi

log "Render ${DS_TMPL} → ${DS_OUT} (VM_PORT=${VM_PORT})"
sed "s|__VM_PORT__|${VM_PORT}|g" "${DS_TMPL}" > "${DS_OUT}"

if [[ ! -f "${DASH_PROV}" ]]; then
    echo "Ошибка: ${DASH_PROV} не найден (должен быть в репозитории)" >&2
    exit 1
fi
log "Provisioning dashboards.yml уже на месте"

# Проверка наличия dashboards.
DASH_COUNT=$(find "${SCRIPT_DIR}/dashboards" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
log "Dashboards: ${DASH_COUNT} JSON файлов"
if [[ "${DASH_COUNT}" == "0" ]]; then
    log "ПРЕДУПРЕЖДЕНИЕ: нет .json в ${SCRIPT_DIR}/dashboards/"
fi

# Перезагрузить Grafana, если контейнер запущен.
if [[ "${CHAOS_DRY_RUN}" == "true" ]]; then
    chaos_term_remote_cmd "docker restart grafana  # (dry-run)"
else
    if docker ps --filter name=^grafana$ --format '{{.Names}}' 2>/dev/null | grep -q '^grafana$'; then
        log "Перезапуск контейнера grafana для применения provisioning"
        chaos_term_remote_cmd "docker restart grafana"
        docker restart grafana >/dev/null
        sleep 2
        if curl -sf -o /dev/null "http://localhost:${GRAFANA_PORT}/login"; then
            log "✓ Grafana перезапущена и отвечает на /login"
        else
            log "ПРЕДУПРЕЖДЕНИЕ: /login пока недоступен"
        fi
    else
        log "Контейнер grafana не запущен — пропуск restart. Запустите 03-grafana.sh."
    fi
fi

log_section "Готово"
