#!/usr/bin/env bash
# Проверка / сброс tc qdisc на хостах кластера.
# Читает CLUSTER_HOSTS из env.sh; для сброса добавьте флаг -D.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"
chaos_load_env "${SCRIPT_DIR}"

MODE_RESET=false
if [[ "${1:-}" == "-D" ]]; then
    MODE_RESET=true
fi

for HOST in "${CLUSTER_HOSTS[@]}"; do
    echo -n "${HOST}: "
    if [[ "${MODE_RESET}" == true ]]; then
        ssh "${HOST}" "sudo tc qdisc del dev \${NET_IFACE:-eth0} root 2>/dev/null && echo 'CLEAN' || echo 'уже чисто'"
    else
        ssh "${HOST}" \
            "tc qdisc show dev \${NET_IFACE:-eth0} | awk '/^qdisc (prio|netem|tbf).*root/{found=1; print \$0} END{if(!found) print \"CLEAN\"}'"
    fi
done
