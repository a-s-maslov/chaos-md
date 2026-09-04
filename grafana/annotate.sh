#!/usr/bin/env bash
# Создаёт аннотацию в Grafana (POST /api/annotations).
# Требует: GRAFANA_URL и GRAFANA_TOKEN в env.local.sh (или в окружении).
#
# Текст аннотации — обязателен, задаётся после всех ключей (один или несколько аргументов
# склеиваются через пробел).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${REPO_DIR}/lib/config.sh"
chaos_load_env "${REPO_DIR}"

# Дашборд по умолчанию (UID берётся из пути /d/<uid>/...).
# Можно задать через GRAFANA_DASHBOARD_URL в env.local.sh, либо через -u/--url.
DEFAULT_DASHBOARD_URL="${GRAFANA_DASHBOARD_URL:-}"

usage() {
    cat <<EOF
Использование:
  $(basename "$0") [КЛЮЧИ] <текст аннотации>...

Текст обязателен и идёт после всех ключей (несколько слов — несколько аргументов).

Ключи:
  -h, --help                 Эта справка
  -a, --all                  Аннотация на весь org (без привязки к дашборду)
  -u, --url URL              Ссылка на дашборд (по умолчанию: GRAFANA_DASHBOARD_URL)
  -U, --uid UID              UID дашборда явно (имеет приоритет над -u)
  -g, --grafana-url URL      Базовый URL API (по умолчанию: GRAFANA_URL из env)
  -t, --tags СПИСОК          Теги через запятую (по умолчанию: chaos)
  -T, --time MS              Время начала, мс с epoch (по умолчанию: сейчас)
  -E, --time-end MS          Конец интервала, мс (по умолчанию: как -T — точечная аннотация)

Переменные: GRAFANA_URL, GRAFANA_TOKEN, GRAFANA_DASHBOARD_URL.

Примеры:
  $(basename "$0") "CPU chaos start"
  $(basename "$0") -t chaos,manual "Проверка после деплоя"
  $(basename "$0") -a "Событие на всех дашбордах с подходящим query"
  $(basename "$0") -U other-dashboard "Только на указанном UID"
  $(basename "$0") -- "-текст начинается как ключ"
EOF
}

_grafana_time_ms() {
    date +%s%3N 2>/dev/null | grep -q '^[0-9]\{13\}$' \
        && date +%s%3N \
        || python3 -c "import time; print(int(time.time()*1000))" 2>/dev/null \
        || echo $(( $(date +%s) * 1000 ))
}

ALL_DASHBOARDS=false
DASHBOARD_URL="${DEFAULT_DASHBOARD_URL}"
EXPLICIT_UID=""
GRAFANA_API_BASE="${GRAFANA_URL:-}"
TAGS_CSV="chaos"
TIME_MS=""
TIME_END_MS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)        usage; exit 0 ;;
        -a|--all)         ALL_DASHBOARDS=true; shift ;;
        -u|--url)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            DASHBOARD_URL="$2"; shift 2 ;;
        -U|--uid)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            EXPLICIT_UID="$2"; shift 2 ;;
        -g|--grafana-url)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            GRAFANA_API_BASE="$2"; shift 2 ;;
        -t|--tags)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            TAGS_CSV="$2"; shift 2 ;;
        -T|--time)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            TIME_MS="$2"; shift 2 ;;
        -E|--time-end)
            [[ $# -lt 2 ]] && { echo "Ошибка: $1 требует значение" >&2; usage >&2; exit 1; }
            TIME_END_MS="$2"; shift 2 ;;
        --) shift; break ;;
        -*) echo "Неизвестный ключ: $1" >&2; usage >&2; exit 1 ;;
        *)  break ;;
    esac
done

if [[ $# -lt 1 ]]; then
    usage >&2
    exit 1
fi

ANN_TEXT="$*"

if [[ -z "${GRAFANA_API_BASE}" || -z "${GRAFANA_TOKEN:-}" ]]; then
    echo "Ошибка: задайте GRAFANA_URL (-g) и GRAFANA_TOKEN" >&2
    exit 1
fi

if [[ "${ALL_DASHBOARDS}" == true && -n "${EXPLICIT_UID}" ]]; then
    echo "Ошибка: нельзя одновременно -a/--all и -U/--uid" >&2
    exit 1
fi

[[ -z "${TIME_MS}" ]] && TIME_MS="$(_grafana_time_ms)"
[[ -z "${TIME_END_MS}" ]] && TIME_END_MS="${TIME_MS}"

DASH_UID=""
if [[ "${ALL_DASHBOARDS}" != true ]]; then
    if [[ -n "${EXPLICIT_UID}" ]]; then
        DASH_UID="${EXPLICIT_UID}"
    elif [[ -z "${DASHBOARD_URL}" ]]; then
        echo "Ошибка: не задан дашборд (-u/--url, -U/--uid или GRAFANA_DASHBOARD_URL в env)" >&2
        echo "       Или используйте -a для org-wide аннотации." >&2
        exit 1
    else
        DASH_UID="$(DASHBOARD_URL_FOR_PARSE="${DASHBOARD_URL}" python3 <<'PY'
from urllib.parse import urlparse
import os
u = os.environ["DASHBOARD_URL_FOR_PARSE"]
p = urlparse(u)
parts = [x for x in p.path.split("/") if x]
if len(parts) >= 2 and parts[0] == "d":
    print(parts[1])
else:
    raise SystemExit("не удалось извлечь UID дашборда из URL (ожидается путь /d/<uid>/...)")
PY
)" || {
            echo "Ошибка: ${DASH_UID}" >&2
            exit 1
        }
    fi
fi

PAYLOAD="$(ANN_TEXT="${ANN_TEXT}" TAGS_CSV="${TAGS_CSV}" TIME_MS="${TIME_MS}" TIME_END_MS="${TIME_END_MS}" DASH_UID="${DASH_UID}" GFA_ORG_WIDE="${ALL_DASHBOARDS}" python3 <<'PY'
import json, os

text = os.environ["ANN_TEXT"]
tags = [t.strip() for t in os.environ["TAGS_CSV"].split(",") if t.strip()]
t0 = int(os.environ["TIME_MS"])
t1 = int(os.environ["TIME_END_MS"])
uid = os.environ.get("DASH_UID", "").strip()
org_wide = os.environ.get("GFA_ORG_WIDE", "") == "true"

body = {"time": t0, "timeEnd": t1, "tags": tags, "text": text}
if not org_wide and uid:
    body["dashboardUID"] = uid
print(json.dumps(body))
PY
)"

resp_file=$(mktemp)
trap 'rm -f "${resp_file}"' EXIT
http_code=$(curl -sk --max-time 15 \
    -o "${resp_file}" -w "%{http_code}" \
    -XPOST "${GRAFANA_API_BASE%/}/api/annotations" \
    -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "${PAYLOAD}")

if [[ "${http_code}" != "200" ]]; then
    echo "Ошибка Grafana HTTP ${http_code}: $(cat "${resp_file}")" >&2
    exit 1
fi

python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print('id=', d.get('id','?'))" "${resp_file}" 2>/dev/null || cat "${resp_file}"
