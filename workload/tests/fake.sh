#!/usr/bin/env bash
set -euo pipefail

READY_FILE="${FAKE_WORKLOAD_READY_FILE:?}"
case "${1:-}" in
    info) echo "implementation : fake" ;;
    prepare) echo "fake prepared" ;;
    run)
        cleanup() { rm -f "${READY_FILE}"; }
        trap 'cleanup; exit 0' INT TERM
        trap cleanup EXIT
        printf 'ready\n' > "${READY_FILE}"
        while true; do sleep 1; done
        ;;
    health) [[ -f "${READY_FILE}" ]] ;;
    action) printf '%s\n' "${*:2}" > "${FAKE_WORKLOAD_ACTION_FILE:?}" ;;
    cleanup) rm -f "${READY_FILE}" ;;
    *) exit 2 ;;
esac
