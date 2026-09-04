#!/usr/bin/env bash
# Деплой дашборда Grafana через API из
# grafana/dashboards/chaos/chaos-tests.json.
# Создаёт дашборд если не существует, обновляет существующий (по заголовку).
# Последнее использованное имя сохраняет в grafana/.chaos-grafana-last.
#
# Используется для горячего апдейта дашборда на уже работающей Grafana
# (любой стенд). Альтернатива — provisioning из 04-dashboards-provision.sh.
#
# Сценарий использования:
#   ./grafana/deploy-dashboard.sh           # интерактивно; дефолт — последнее имя
#   GRAFANA_DASH_NAME="Chaos Tests" ./grafana/deploy-dashboard.sh
#   GRAFANA_DASH_FILE="grafana/dashboards/chaos/deep-tech-search-demo.json" \
#     GRAFANA_DASH_NAME="Deep Tech: YDB Search Demo" ./grafana/deploy-dashboard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${REPO_DIR}/lib/config.sh"
chaos_load_env "${REPO_DIR}"

DASHBOARD_FILE="${GRAFANA_DASH_FILE:-grafana/dashboards/chaos/chaos-tests.json}"
if [[ "${DASHBOARD_FILE}" = /* ]]; then
    DASHBOARD_JSON="${DASHBOARD_FILE}"
else
    DASHBOARD_JSON="${REPO_DIR}/${DASHBOARD_FILE}"
fi
STATE_FILE="${SCRIPT_DIR}/.chaos-grafana-last"
FALLBACK_NAME="Chaos Tests"

if [[ -z "${GRAFANA_URL:-}" || -z "${GRAFANA_TOKEN:-}" ]]; then
    echo "Ошибка: GRAFANA_URL и GRAFANA_TOKEN должны быть заданы (env.local.sh)" >&2
    exit 1
fi

if [[ ! -f "${DASHBOARD_JSON}" ]]; then
    echo "Ошибка: ${DASHBOARD_JSON} не найден" >&2
    exit 1
fi

default="${FALLBACK_NAME}"
[[ -f "${STATE_FILE}" ]] && default=$(tr -d '\n' < "${STATE_FILE}")

if [[ -n "${GRAFANA_DASH_NAME:-}" ]]; then
    title="${GRAFANA_DASH_NAME}"
else
    printf "Имя дашборда [%s]: " "${default}"
    read -r input_name
    title="${input_name:-${default}}"
fi

echo "→ Деплой: «${title}»"

dash_url=$(GRAFANA_URL="${GRAFANA_URL}" GRAFANA_TOKEN="${GRAFANA_TOKEN}" \
    DASH_JSON="${DASHBOARD_JSON}" DASH_TITLE="${title}" \
    python3 <<'PY'
import json, os, ssl, sys, urllib.error, urllib.parse, urllib.request

url   = os.environ["GRAFANA_URL"].rstrip("/")
token = os.environ["GRAFANA_TOKEN"]
title = os.environ["DASH_TITLE"]

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

def api(method, path, body=None):
    req = urllib.request.Request(
        f"{url}{path}",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        method=method,
        data=json.dumps(body).encode() if body is not None else None,
    )
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=15) as r:
            return json.loads(r.read())
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
        sys.exit(1)

with open(os.environ["DASH_JSON"]) as f:
    dash = json.load(f)
dash["title"] = title

results = api("GET", f"/api/search?query={urllib.parse.quote(title)}&type=dash-db")
existing = next((d for d in results if d["title"] == title), None)

if existing:
    full = api("GET", f"/api/dashboards/uid/{existing['uid']}")
    dash["id"]      = full["dashboard"]["id"]
    dash["uid"]     = existing["uid"]
    dash["version"] = full["dashboard"].get("version", 1)
    payload = {"dashboard": dash, "overwrite": True, "message": "deploy-dashboard.sh"}
    print(f"  обновление uid={existing['uid']}", file=sys.stderr)
else:
    dash.pop("id",  None)
    dash.pop("uid", None)
    payload = {"dashboard": dash, "overwrite": False, "message": "deploy-dashboard.sh"}
    print("  создание нового дашборда", file=sys.stderr)

r = api("POST", "/api/dashboards/db", payload)
print(f"{url}{r.get('url', '')}")
PY
)

echo "${title}" > "${STATE_FILE}"
echo "✓ ${dash_url}"
