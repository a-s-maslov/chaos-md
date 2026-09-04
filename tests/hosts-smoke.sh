#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/hosts.sh
source "${ROOT}/lib/hosts.sh"

SCOPE_SINGLE=true
SCOPE_DC=false
SCOPE_DC_ALT=false
NODE_HOST=""
DC_HOSTS=()
DC_ALT_HOSTS=()

if chaos_resolve_targets 2>/dev/null; then
    echo "empty single-host target was accepted" >&2
    exit 1
fi

NODE_HOST="node-01.example.test"
chaos_resolve_targets
[[ "${SCOPE_LABEL}" == "node" ]]
[[ ${#TARGET_HOSTS[@]} -eq 1 ]]
[[ "${TARGET_HOSTS[0]}" == "node-01.example.test" ]]

SCOPE_SINGLE=false
SCOPE_DC=true
if chaos_resolve_targets 2>/dev/null; then
    echo "empty DC target list was accepted" >&2
    exit 1
fi

DC_HOSTS=(node-01.example.test node-02.example.test)
chaos_resolve_targets
[[ "${SCOPE_LABEL}" == "dc" ]]
[[ ${#TARGET_HOSTS[@]} -eq 2 ]]

echo "host target validation smoke: OK"
