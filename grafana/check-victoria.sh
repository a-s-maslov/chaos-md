#!/usr/bin/env bash
# Диагностика VictoriaMetrics: статус, targets, метрики, последние данные.
#
# Запускать НА ${MON_HOST} ${MON_HOST} для проверки что данные собираются.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/lib/config.sh"
chaos_load_env "${REPO_DIR}"
source "${REPO_DIR}/lib/term.sh"

VM_URL="http://localhost:${VM_PORT}"
TIMEOUT=10

_sep() { printf '%0.s─' {1..80}; printf '\n'; }

usage() {
    cat <<EOF
$(basename "$0") — VictoriaMetrics diagnostic: targets, metrics, data freshness.

  --help    Справка
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# URL-encode helper для query параметров
_urlenc() { printf '%s' "$1" | jq -sRr @uri; }

# Выполнить query через /api/v1/query, вернуть скаляр (.data.result[0].value[1])
_vm_query() {
    local q="$1"
    curl -sf -m ${TIMEOUT} -G --data-urlencode "query=${q}" "${VM_URL}/api/v1/query" 2>/dev/null | \
        jq -r '.data.result[0].value[1] // empty' 2>/dev/null || echo ""
}

echo ""
_sep
printf '%b=== VictoriaMetrics Diagnostic ===%b\n' "${C_HOST}" "${C_RESET}"
_sep

# === Health Check ===
printf '\n%b[1] Health%b\n' "${C_HOST}" "${C_RESET}"
if curl -sf -m ${TIMEOUT} "${VM_URL}/-/ready" > /dev/null 2>&1; then
    printf '  %b✓ Ready%b\n' "${C_HOST}" "${C_RESET}"
else
    printf '  %bERROR: Not ready%b\n' "${C_TIMER}" "${C_RESET}"
    exit 1
fi

# === Version ===
VERSION=$(curl -sf -m ${TIMEOUT} "${VM_URL}/api/v1/status/buildinfo" 2>/dev/null | jq -r '.data.version // .version // "unknown"' || echo "unknown")
printf '  Version: %s\n' "$VERSION"

# === Targets Status ===
printf '\n%b[2] Scrape Targets%b\n' "${C_HOST}" "${C_RESET}"

TARGETS_JSON=$(curl -sf -m ${TIMEOUT} "${VM_URL}/api/v1/targets" 2>/dev/null || echo '{"data":{"activeTargets":[],"droppedTargets":[]}}')

ACTIVE=$(echo "$TARGETS_JSON" | jq '.data.activeTargets | length' 2>/dev/null || echo 0)
DROPPED=$(echo "$TARGETS_JSON" | jq '.data.droppedTargets | length' 2>/dev/null || echo 0)

printf '  Active: %d, Dropped: %d\n' "$ACTIVE" "$DROPPED"

# По jobs
printf '\n  %bActive targets by job:%b\n' "${C_TIMER}" "${C_RESET}"
if [[ $ACTIVE -gt 0 ]]; then
    echo "$TARGETS_JSON" | jq -r '.data.activeTargets[] | "\(.labels.job)\t\(.health)\t\(.labels.instance)\t\(.lastSamplesScraped // 0)"' 2>/dev/null | \
        awk -F'\t' '{
            jobs[$1]++
            health[$1"|"$2]++
            samples[$1] += $4
        }
        END {
            for (j in jobs) {
                up = health[j"|up"] + 0
                down = health[j"|down"] + 0
                printf "    %-20s %d targets (up=%d, down=%d), %d samples/scrape\n", j ":", jobs[j], up, down, samples[j]
            }
        }' | sort
else
    printf '    (no active targets)\n'
fi

# Ошибки скрейпа
ERRORS=$(echo "$TARGETS_JSON" | jq -r '.data.activeTargets[] | select(.lastError != "" and .lastError != null) | "    \(.labels.job)/\(.labels.instance): \(.lastError)"' 2>/dev/null)
if [[ -n "$ERRORS" ]]; then
    printf '\n  %bScrape errors:%b\n' "${C_TIMER}" "${C_RESET}"
    echo "$ERRORS"
fi

# === Total Metrics Count ===
printf '\n%b[3] Total Metrics in Storage%b\n' "${C_HOST}" "${C_RESET}"

TOTAL=$(curl -sf -m ${TIMEOUT} "${VM_URL}/api/v1/label/__name__/values" 2>/dev/null | jq '.data | length' 2>/dev/null || echo 0)
printf '  Unique metric names: %s\n' "$TOTAL"

# === Metrics Count by Job ===
printf '\n%b[4] Unique Metric Names by Job%b\n' "${C_HOST}" "${C_RESET}"

CHECK_JOBS=(workload node ydb/ydb ydb/kqp ydb/grpc)
for job in "${CHECK_JOBS[@]}"; do
    # count of unique metric names for this job
    COUNT=$(_vm_query "count(count by (__name__) ({job=\"${job}\"}))")
    if [[ -n "$COUNT" && "$COUNT" != "0" ]]; then
        printf '  %b✓ %-20s %s metric names%b\n' "${C_HOST}" "$job:" "$COUNT" "${C_RESET}"
    else
        printf '  %b✗ %-20s 0 metrics%b\n' "${C_TIMER}" "$job:" "${C_RESET}"
    fi
done

# === Data Freshness (по up метрикам) ===
printf '\n%b[5] Data Freshness (per target)%b\n' "${C_HOST}" "${C_RESET}"

UP_JSON=$(curl -sf -m ${TIMEOUT} -G --data-urlencode "query=up" "${VM_URL}/api/v1/query" 2>/dev/null || echo '{"data":{"result":[]}}')
RESULT_COUNT=$(echo "$UP_JSON" | jq '.data.result | length' 2>/dev/null || echo 0)

if [[ $RESULT_COUNT -gt 0 ]]; then
    NOW=$(date +%s)
    echo "$UP_JSON" | jq -r '.data.result[] | "\(.metric.job)\t\(.metric.instance)\t\(.value[0])\t\(.value[1])"' 2>/dev/null | \
        while IFS=$'\t' read -r job instance ts value; do
            ts_int=${ts%.*}
            age=$(( NOW - ts_int ))
            if [[ $age -lt 60 ]]; then
                age_str="${age}s ago"
            elif [[ $age -lt 3600 ]]; then
                age_str="$(( age / 60 ))m ago"
            else
                age_str="$(( age / 3600 ))h ago"
            fi
            if [[ "$value" == "1" ]]; then
                status="${C_HOST}up${C_RESET}"
            else
                status="${C_TIMER}down${C_RESET}"
            fi
            printf '  %-15s %-50s %b (last: %s)\n' "$job" "$instance" "$status" "$age_str"
        done
else
    printf '  (no up metrics — possibly no targets)\n'
fi

# === Sample Metrics ===
printf '\n%b[6] Sample Metric Names%b\n' "${C_HOST}" "${C_RESET}"

for job in "${CHECK_JOBS[@]}"; do
    SAMPLE=$(curl -sf -m ${TIMEOUT} -G --data-urlencode "query=count by (__name__) ({job=\"${job}\"})" "${VM_URL}/api/v1/query" 2>/dev/null | \
        jq -r '.data.result[0:3] | .[] | .metric.__name__' 2>/dev/null | head -3 || echo "")

    if [[ -n "$SAMPLE" ]]; then
        printf '  %b%s:%b\n' "${C_HOST}" "$job" "${C_RESET}"
        echo "$SAMPLE" | while read m; do
            printf '    - %s\n' "$m"
        done
    fi
done

_sep
printf '%bDone%b\n' "${C_HOST}" "${C_RESET}"
