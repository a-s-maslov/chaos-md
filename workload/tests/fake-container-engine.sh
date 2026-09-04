#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="${FAKE_ENGINE_LOG_FILE:?}"

if [[ "${1:-}" == inspect ]]; then
    printf '%s\n' "${FAKE_YDB_IP:-10.0.0.42}"
    exit 0
fi

if [[ "${1:-}" == compose ]]; then
    : "${YDB_CONNECTION_STRING:?adapter did not export YDB_CONNECTION_STRING}"
    : "${YDB_NODE_ADDRESS_OVERRIDE:?adapter did not export YDB_NODE_ADDRESS_OVERRIDE}"
    printf 'connection=%s override=%s args=%s\n' \
        "${YDB_CONNECTION_STRING}" "${YDB_NODE_ADDRESS_OVERRIDE}" "$*" >> "${LOG_FILE}"
    exit 0
fi

printf 'unexpected fake engine invocation: %s\n' "$*" >&2
exit 2
