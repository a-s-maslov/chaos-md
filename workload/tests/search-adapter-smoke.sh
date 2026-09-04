#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKLOAD_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

printf 'services: {}\n' > "${TMP}/compose.yaml"
export CHAOS_WORKLOAD_SKIP_LOCAL_ENV=true
export SEARCH_WORKLOAD_MODE=compose
export SEARCH_WORKLOAD_PROJECT_DIR="${TMP}"
export SEARCH_WORKLOAD_COMPOSE_FILE=compose.yaml
export SEARCH_WORKLOAD_CONTAINER_ENGINE="${SCRIPT_DIR}/fake-container-engine.sh"
export SEARCH_WORKLOAD_YDB_CONTAINER=ydb-test
export SEARCH_WORKLOAD_YDB_NETWORK=test-net
export SEARCH_WORKLOAD_YDB_PORT=2136
export SEARCH_WORKLOAD_YDB_DATABASE=/local
export SEARCH_WORKLOAD_PREPARE_TIMEOUT=5s
export FAKE_ENGINE_LOG_FILE="${TMP}/engine.log"
export FAKE_YDB_IP=10.0.0.42

bash "${WORKLOAD_DIR}/adapters/search.sh" prepare

grep -q 'connection=grpc://10.0.0.42:2136/local' "${FAKE_ENGINE_LOG_FILE}"
grep -q 'override=10.0.0.42' "${FAKE_ENGINE_LOG_FILE}"
grep -q 'compose -f compose.yaml build workload' "${FAKE_ENGINE_LOG_FILE}"
grep -q 'compose -f compose.yaml run --rm --no-deps workload' "${FAKE_ENGINE_LOG_FILE}"

printf '#!/usr/bin/env bash\nexit 0\n' > "${TMP}/search-workload"
chmod +x "${TMP}/search-workload"
printf '{}\n' > "${TMP}/workload.json"
export SEARCH_WORKLOAD_MODE=binary
export SEARCH_WORKLOAD_BIN="${TMP}/search-workload"
export SEARCH_WORKLOAD_CONFIG="${TMP}/workload.json"
export WORKLOAD_DRY_RUN=true
reset_output="$(bash "${WORKLOAD_DIR}/adapters/search.sh" action reset-fulltext)"
grep -q -- '-wait-timeout 15m reset-fulltext' <<<"${reset_output}"
reset_vector_output="$(bash "${WORKLOAD_DIR}/adapters/search.sh" action reset-vector)"
grep -q -- '-wait-timeout 15m reset-vector' <<<"${reset_vector_output}"
elastic_output="$(bash "${WORKLOAD_DIR}/adapters/search.sh" action partition-elastic fulltext)"
grep -q -- '-scope fulltext partition-elastic' <<<"${elastic_output}"

# The health adapter must consume the complete response before inspecting it.
# With `curl | grep -q` and pipefail, grep closes the pipe after the first match
# and a real curl can return 23 (write error), producing a false health failure.
metrics_fixture="${TMP}/metrics.txt"
for _ in {1..10000}; do
    printf 'ydb_workload_rps{scenario="fulltext"} 1\n'
done > "${metrics_fixture}"
cat > "${TMP}/curl" <<'EOF'
#!/usr/bin/env bash
cat "${METRICS_FIXTURE}"
EOF
chmod +x "${TMP}/curl"
export METRICS_FIXTURE="${metrics_fixture}"
export SEARCH_WORKLOAD_METRICS_URL="http://127.0.0.1:19091/metrics"
PATH="${TMP}:${PATH}" bash "${WORKLOAD_DIR}/adapters/search.sh" health

echo "search adapter compose smoke: OK"
