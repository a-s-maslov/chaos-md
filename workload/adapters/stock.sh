#!/usr/bin/env bash
# Adapter существующего ydb workload stock. Старый workload.sh не изменяется.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPT="${STOCK_WORKLOAD_SCRIPT:-${WORKLOAD_DIR}/workload.sh}"
DRY_RUN="${WORKLOAD_DRY_RUN:-false}"

run_old() {
    args=("$@")
    [[ "${DRY_RUN}" == true ]] && args+=(--dry-run)
    bash "${SCRIPT}" "${args[@]}"
}

case "${1:-}" in
    info) run_old info ;;
    prepare) run_old init ;;
    run) run_old run ;;
    health)
        if [[ -n "${STOCK_WORKLOAD_HEALTH_URL:-}" ]]; then
            curl -fsS --max-time 2 "${STOCK_WORKLOAD_HEALTH_URL}" >/dev/null
        fi
        ;;
    stop) : ;;
    cleanup)
        [[ " ${*:2} " == *" --yes "* ]] || { echo "cleanup требует --yes" >&2; exit 2; }
        run_old cleanup --yes
        ;;
    *) echo "stock adapter: неизвестная команда ${1:-}" >&2; exit 2 ;;
esac
