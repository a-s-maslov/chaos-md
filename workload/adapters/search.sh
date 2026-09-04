#!/usr/bin/env bash
# Adapter deep-tech-ydb-searches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ "${CHAOS_WORKLOAD_SKIP_LOCAL_ENV:-false}" != true && -f "${WORKLOAD_DIR}/env.local.sh" ]]; then
    source "${WORKLOAD_DIR}/env.local.sh"
fi

MODE="${SEARCH_WORKLOAD_MODE:-binary}"
BIN="${SEARCH_WORKLOAD_BIN:-}"
CONFIG="${SEARCH_WORKLOAD_CONFIG:-}"
METRICS_URL="${SEARCH_WORKLOAD_METRICS_URL:-http://127.0.0.1:9091/metrics}"
PREPARE_TIMEOUT="${SEARCH_WORKLOAD_PREPARE_TIMEOUT:-5m}"
PROJECT_DIR="${SEARCH_WORKLOAD_PROJECT_DIR:-}"
COMPOSE_FILE="${SEARCH_WORKLOAD_COMPOSE_FILE:-compose.workload.yaml}"
ENGINE="${SEARCH_WORKLOAD_CONTAINER_ENGINE:-docker}"
YDB_CONTAINER="${SEARCH_WORKLOAD_YDB_CONTAINER:-}"
YDB_NETWORK="${SEARCH_WORKLOAD_YDB_NETWORK:-chaos-monitoring}"
YDB_PORT="${SEARCH_WORKLOAD_YDB_PORT:-2136}"
YDB_DATABASE="${SEARCH_WORKLOAD_YDB_DATABASE:-/local}"
DRY_RUN="${WORKLOAD_DRY_RUN:-false}"
PROFILE="${CHAOS_WORKLOAD_PROFILE:-}"
PROFILE_ARGS=()
if [[ -n "${PROFILE}" ]]; then
    PROFILE_ARGS=(-profile "${PROFILE}")
fi
export WORKLOAD_PROFILE="${PROFILE}"

require_config() {
    [[ -n "${BIN}" ]] || { echo "SEARCH_WORKLOAD_BIN не задан" >&2; exit 2; }
    [[ -x "${BIN}" || -f "${BIN}" ]] || { echo "Бинарник не найден: ${BIN}" >&2; exit 2; }
    [[ -n "${CONFIG}" ]] || { echo "SEARCH_WORKLOAD_CONFIG не задан" >&2; exit 2; }
    [[ -f "${CONFIG}" ]] || { echo "Конфигурация не найдена: ${CONFIG}" >&2; exit 2; }
}

require_compose() {
    [[ -n "${PROJECT_DIR}" && -d "${PROJECT_DIR}" ]] || { echo "SEARCH_WORKLOAD_PROJECT_DIR не задан или не существует" >&2; exit 2; }
    [[ -f "${PROJECT_DIR}/${COMPOSE_FILE}" ]] || { echo "Compose-файл не найден: ${PROJECT_DIR}/${COMPOSE_FILE}" >&2; exit 2; }
}

resolve_container_ydb() {
    [[ -n "${YDB_CONTAINER}" ]] || return 0
    local address
    address="$(MSYS_NO_PATHCONV=1 "${ENGINE}" inspect \
        --format "{{with index .NetworkSettings.Networks \"${YDB_NETWORK}\"}}{{.IPAddress}}{{end}}" \
        "${YDB_CONTAINER}")"
    [[ -n "${address}" ]] || {
        echo "Не найден IP контейнера ${YDB_CONTAINER} в сети ${YDB_NETWORK}" >&2
        return 1
    }
    export YDB_CONNECTION_STRING="grpc://${address}:${YDB_PORT}${YDB_DATABASE}"
    export YDB_NODE_ADDRESS_OVERRIDE="${address}"
}

compose() {
    resolve_container_ydb
    (cd "${PROJECT_DIR}" && MSYS_NO_PATHCONV=1 "${ENGINE}" compose -f "${COMPOSE_FILE}" "$@")
}

compose_with_timeout() {
    local duration="$1"
    shift
    resolve_container_ydb
    (cd "${PROJECT_DIR}" && MSYS_NO_PATHCONV=1 timeout --preserve-status "${duration}" \
        "${ENGINE}" compose -f "${COMPOSE_FILE}" "$@")
}

print_cmd() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
}

run_cmd() {
    if [[ "${DRY_RUN}" == true ]]; then
        print_cmd "$@"
    else
        "$@"
    fi
}

base=("${BIN}" -config "${CONFIG}" "${PROFILE_ARGS[@]}")

case "${1:-}" in
    info)
        echo "implementation : deep-tech-ydb-searches"
        echo "mode           : ${MODE}"
        echo "binary         : ${BIN:-(не задан)}"
        echo "config         : ${CONFIG:-(не задан)}"
        echo "metrics        : ${METRICS_URL:-(не проверяются)}"
        echo "profile        : ${PROFILE:-(default)}"
        if [[ "${MODE}" == compose ]]; then
            echo "project        : ${PROJECT_DIR:-(не задан)}"
            echo "compose file   : ${COMPOSE_FILE}"
            echo "engine         : ${ENGINE}"
            if [[ -n "${YDB_CONTAINER}" ]]; then
                echo "local YDB      : ${YDB_CONTAINER} (${YDB_NETWORK})"
            fi
        fi
        ;;
    prepare)
        if [[ "${MODE}" == compose ]]; then
            require_compose
            run_cmd compose build workload
            if [[ "${DRY_RUN}" == true ]]; then
                print_cmd timeout --preserve-status "${PREPARE_TIMEOUT}" compose run --rm --no-deps workload -config /config/workload.json "${PROFILE_ARGS[@]}" check
            else
                compose_with_timeout "${PREPARE_TIMEOUT}" run --rm --no-deps workload -config /config/workload.json "${PROFILE_ARGS[@]}" check
            fi
        else
            require_config
            run_cmd "${base[@]}" check
        fi
        ;;
    run)
        if [[ "${MODE}" == compose ]]; then
            require_compose
            if [[ "${DRY_RUN}" == true ]]; then
                print_cmd "${ENGINE}" compose -f "${PROJECT_DIR}/${COMPOSE_FILE}" up --no-build --no-deps workload
            else
                cleanup() { compose stop workload >/dev/null 2>&1 || true; }
                trap cleanup EXIT INT TERM
                compose up --no-build --no-deps workload
            fi
        else
            require_config
            exec "${base[@]}" run
        fi
        ;;
    health)
        if [[ -z "${METRICS_URL}" ]]; then
            exit 0
        fi
        metrics="$(curl -fsS --max-time 2 "${METRICS_URL}")"
        grep -q '^ydb_workload_' <<<"${metrics}"
        ;;
    stop)
        if [[ "${MODE}" == compose ]]; then
            require_compose
            run_cmd compose stop workload
        fi
        ;;
    action)
        require_config
        action_name="${2:-}"
        scope="${3:-all}"
        case "${action_name}" in
            partitions)
                run_cmd "${base[@]}" partitions
                ;;
            partition-fixed|partition-auto|partition-elastic)
                run_cmd "${base[@]}" -scope "${scope}" "${action_name}"
                ;;
            reset-fulltext|reset-vector)
                run_cmd "${base[@]}" -wait-timeout "${SEARCH_WORKLOAD_INDEX_WAIT_TIMEOUT:-15m}" "${action_name}"
                ;;
            *)
                echo "search adapter: неизвестное действие ${action_name:-<пусто>}" >&2
                echo "доступны: partitions, partition-fixed [scope], partition-auto [scope], partition-elastic [scope], reset-fulltext, reset-vector" >&2
                exit 2
                ;;
        esac
        ;;
    cleanup)
        echo "no-op: reusable workshop schema is not owned by chaos-md"
        ;;
    *) echo "search adapter: неизвестная команда ${1:-}" >&2; exit 2 ;;
esac
