#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
TEST_NAME="chaos-md-annotation-smoke-$$"
LEGACY_NAME="chaos-md-annotation-legacy-$$"

cleanup() {
    rm -rf "${TMP}"
    rm -f "/tmp/grafana-chaos-${TEST_NAME}.id" \
        "/tmp/grafana-chaos-${LEGACY_NAME}.id"
}
trap cleanup EXIT

mkdir -p "${TMP}/bin" "${TMP}/capture"
cat >"${TMP}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
method="GET"
payload=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -XPOST) method="POST" ;;
        -XPATCH) method="PATCH" ;;
        -d)
            payload="${2:-}"
            shift
            ;;
    esac
    shift
done
printf '%s' "${payload}" >"${CAPTURE_DIR}/${method}.json"
[[ "${method}" != POST ]] || printf '{"id":987654}\n'
EOF
chmod +x "${TMP}/bin/curl"

export PATH="${TMP}/bin:${PATH}"
export CAPTURE_DIR="${TMP}/capture"
export GRAFANA_URL="http://grafana.invalid"
export GRAFANA_TOKEN="smoke-token"

# shellcheck source=../lib/grafana.sh
source "${ROOT}/lib/grafana.sh"

grafana_region_open "${TEST_NAME}" "workload interval" workload
grep -Fq '"tags":["chaos","event:workload","'"${TEST_NAME}"'"]' \
    "${CAPTURE_DIR}/POST.json"
grafana_region_close "${TEST_NAME}"
grep -Fq '"timeEnd":' "${CAPTURE_DIR}/PATCH.json"

# Старые вызовы с двумя аргументами остаются валидны и считаются отказами.
grafana_region_open "${LEGACY_NAME}" "legacy failure"
grep -Fq '"tags":["chaos","event:failure","'"${LEGACY_NAME}"'"]' \
    "${CAPTURE_DIR}/POST.json"
grafana_region_close "${LEGACY_NAME}"

echo "grafana annotations smoke: OK"
