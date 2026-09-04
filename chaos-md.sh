#!/usr/bin/env bash
# Запуск TUI-диспетчера Chaos MD из корня репозитория.
# macOS: нативный бинарник из dist/ (cargo build --release).
# Linux: статический musl-бинарник из dist/ (make orch, нужен Docker).
#
# Опции launcher-а:
#   --dev                    запустить через cargo run --release
#   --workload TYPE          запустить workload на время всего chaos-прогона
#   --workload-profile NAME  выбрать именованный профиль workload
#   --skip-workload-prepare  не выполнять prepare перед запуском workload
# Остальные аргументы, включая -d/--dry-run, передаются в chaos-md.

set -e
REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
OS="$(uname -s)"
DEV_MODE=0
WORKLOAD_TYPE="${CHAOS_WORKLOAD_TYPE:-}"
WORKLOAD_PROFILE="${CHAOS_WORKLOAD_PROFILE:-}"
WORKLOAD_PREPARE=1
PASSTHROUGH=()

source "${REPO_ROOT}/lib/config.sh"
chaos_load_env "${REPO_ROOT}"

# Rust выбирает shell для запуска сценариев по переменной окружения. Значение
# из env.sh/env.local.sh поэтому нужно явно передать дочернему процессу.
if [[ -n "${CHAOS_BASH_BIN:-}" ]]; then
    export CHAOS_BASH_BIN
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dev)
            DEV_MODE=1
            shift
            ;;
        --workload)
            [[ $# -ge 2 ]] || { echo "--workload требует TYPE" >&2; exit 2; }
            WORKLOAD_TYPE="$2"
            shift 2
            ;;
        --workload-profile)
            [[ $# -ge 2 ]] || { echo "--workload-profile требует NAME" >&2; exit 2; }
            WORKLOAD_PROFILE="$2"
            shift 2
            ;;
        --skip-workload-prepare)
            WORKLOAD_PREPARE=0
            shift
            ;;
        *)
            PASSTHROUGH+=("$1")
            shift
            ;;
    esac
done

WORKLOAD_STARTED=0
workload_manager() {
    local profile_args=()
    [[ -n "${WORKLOAD_PROFILE}" ]] && profile_args=(--profile "${WORKLOAD_PROFILE}")
    bash "${REPO_ROOT}/workload/manage.sh" --type "${WORKLOAD_TYPE}" "${profile_args[@]}" "$@"
}

stop_workload() {
    if [[ ${WORKLOAD_STARTED} -eq 1 ]]; then
        workload_manager stop || true
        WORKLOAD_STARTED=0
    fi
}

if [[ -n "${WORKLOAD_TYPE}" ]]; then
    if [[ ${WORKLOAD_PREPARE} -eq 1 ]]; then
        workload_manager prepare
    fi
    workload_manager start
    WORKLOAD_STARTED=1
    trap stop_workload EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
fi

run_or_exec() {
    if [[ ${WORKLOAD_STARTED} -eq 1 ]]; then
        "$@"
    else
        exec "$@"
    fi
}

if [[ ${DEV_MODE} -eq 1 ]]; then
    cd "${REPO_ROOT}/chaos-md"
    run_or_exec cargo run --release -- --root "${REPO_ROOT}" "${PASSTHROUGH[@]}"
    exit $?
fi

arch="$(uname -m)"

if [[ "${OS}" == "Darwin" ]]; then
    exe="${REPO_ROOT}/dist/chaos-md.darwin_${arch}"
    if [[ ! -f "${exe}" ]]; then
        echo "Нет бинарника: ${exe}" >&2
        echo "Соберите: make orch   (или: cd chaos-md && cargo build --release)" >&2
        exit 1
    fi
else
    case "${arch}" in
        x86_64|amd64)  exe="${REPO_ROOT}/dist/chaos-md.x86_64" ;;
        aarch64|arm64) exe="${REPO_ROOT}/dist/chaos-md.aarch64" ;;
        *)
            echo "Архитектура ${arch} не поддерживается Chaos MD" >&2
            exit 1
            ;;
    esac
fi

if [[ ! -f "${exe}" ]]; then
    echo "Нет бинарника: ${exe}" >&2
    echo "Соберите: make orch  (нужен Docker)" >&2
    exit 1
fi

run_or_exec "${exe}" --root "${REPO_ROOT}" "${PASSTHROUGH[@]}"
