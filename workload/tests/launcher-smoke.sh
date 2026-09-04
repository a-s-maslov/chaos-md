#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TMP="$(mktemp -d)"

cleanup() {
    if [[ -x "${TMP}/repo/workload/manage.sh" ]]; then
        CHAOS_WORKLOAD_ADAPTER_DIR="${TMP}/repo/workload/adapters" \
        CHAOS_WORKLOAD_STATE_DIR="${TMP}/state" \
        CHAOS_WORKLOAD_LOG_DIR="${TMP}/logs" \
        FAKE_WORKLOAD_READY_FILE="${TMP}/ready" \
            bash "${TMP}/repo/workload/manage.sh" --type fake stop >/dev/null 2>&1 || true
    fi
    rm -rf "${TMP}"
}
trap cleanup EXIT

mkdir -p "${TMP}/repo/workload/adapters" "${TMP}/repo/dist" "${TMP}/repo/lib"
cp "${REPO_ROOT}/chaos-md.sh" "${TMP}/repo/chaos-md.sh"
cp "${REPO_ROOT}/lib/config.sh" "${TMP}/repo/lib/config.sh"
cp "${REPO_ROOT}/lib/grafana.sh" "${TMP}/repo/lib/grafana.sh"
cp "${REPO_ROOT}/env.example.sh" "${TMP}/repo/env.sh"
cp "${REPO_ROOT}/workload/manage.sh" "${TMP}/repo/workload/manage.sh"
cp "${SCRIPT_DIR}/fake.sh" "${TMP}/repo/workload/adapters/fake.sh"

cat > "${TMP}/repo/dist/chaos-md.x86_64" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${FAKE_CHAOS_ARGS_FILE:?}"
EOF
chmod +x "${TMP}/repo/chaos-md.sh" \
    "${TMP}/repo/workload/manage.sh" \
    "${TMP}/repo/workload/adapters/fake.sh" \
    "${TMP}/repo/dist/chaos-md.x86_64"

export CHAOS_WORKLOAD_ADAPTER_DIR="${TMP}/repo/workload/adapters"
export CHAOS_WORKLOAD_STATE_DIR="${TMP}/state"
export CHAOS_WORKLOAD_LOG_DIR="${TMP}/logs"
export FAKE_WORKLOAD_READY_FILE="${TMP}/ready"
export FAKE_CHAOS_ARGS_FILE="${TMP}/chaos-args"
export CHAOS_WORKLOAD_ANNOTATIONS=false

bash "${TMP}/repo/chaos-md.sh" --workload fake --workload-profile smoke --headless --tests 01

grep -Fx -- "--root" "${FAKE_CHAOS_ARGS_FILE}" >/dev/null
grep -Fx -- "--headless" "${FAKE_CHAOS_ARGS_FILE}" >/dev/null
grep -Fx -- "--tests" "${FAKE_CHAOS_ARGS_FILE}" >/dev/null
grep -Fx -- "01" "${FAKE_CHAOS_ARGS_FILE}" >/dev/null
[[ ! -e "${FAKE_WORKLOAD_READY_FILE}" ]]

echo "launcher workload lifecycle smoke: OK"
