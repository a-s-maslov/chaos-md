#!/usr/bin/env bash
# Создаёт service account Grafana для chaos-аннотаций и сохраняет токен
# только в локальный env-файл. Значение токена не печатается.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/config.sh
source "${REPO_DIR}/lib/config.sh"
chaos_load_env "${REPO_DIR}"

ENV_FILE="${REPO_DIR}/env.local.sh"
TTL="30d"
MODE="configure"
SERVICE_ACCOUNT_NAME="chaos-md"

usage() {
    cat <<EOF
$(basename "$0") — configure Grafana annotations for chaos-md.

  --env-file PATH  Локальный env-файл для пароля и нового токена
                   (default: ${REPO_DIR}/env.local.sh)
  --ttl DURATION   Срок жизни нового токена: 30d, 12h, 60m или секунды
                   (default: 30d)
  --check          Проверить уже сохранённый токен, ничего не менять
  --test           Создать и закрыть безопасную тестовую аннотацию
  -h, --help       Справка

Для настройки в env-файле должны быть:
  GRAFANA_ADMIN_PASSWORD=...

GRAFANA_URL берётся из env.sh или env-файла. Создаваемый service account:
  name=${SERVICE_ACCOUNT_NAME}, role=Editor
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            [[ $# -ge 2 ]] || { echo "--env-file требует путь" >&2; exit 2; }
            ENV_FILE="$2"; shift 2 ;;
        --ttl)
            [[ $# -ge 2 ]] || { echo "--ttl требует значение" >&2; exit 2; }
            TTL="$2"; shift 2 ;;
        --check) MODE="check"; shift ;;
        --test)  MODE="test"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -f "${ENV_FILE}" ]] || {
    echo "Не найден локальный env-файл: ${ENV_FILE}" >&2
    exit 2
}

# Если репозиторий содержит gitignored-ссылку на централизованное хранилище
# секретов, обновляем сам целевой файл, а не заменяем ссылку.
SECRET_FILE="${ENV_FILE}"
if [[ -L "${ENV_FILE}" ]]; then
    SECRET_FILE="$(readlink -f "${ENV_FILE}")"
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"
GRAFANA_API_BASE="${GRAFANA_URL:-http://127.0.0.1:${GRAFANA_PORT:-3000}}"
GRAFANA_API_BASE="${GRAFANA_API_BASE%/}"

check_token() {
    [[ -n "${GRAFANA_TOKEN:-}" ]] || {
        echo "GRAFANA_TOKEN не задан в ${ENV_FILE}" >&2
        return 1
    }
    curl -sf --max-time 5 \
        -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
        "${GRAFANA_API_BASE}/api/annotations?limit=1" >/dev/null
    echo "Grafana annotations API: OK"
}

ttl_seconds() {
    local value="$1" number unit multiplier
    if [[ "${value}" =~ ^([0-9]+)([smhd]?)$ ]]; then
        number="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        echo "Некорректный TTL: ${value}" >&2
        return 2
    fi
    case "${unit}" in
        ""|s) multiplier=1 ;;
        m) multiplier=60 ;;
        h) multiplier=3600 ;;
        d) multiplier=86400 ;;
    esac
    echo $((number * multiplier))
}

store_token() {
    local token="$1" tmp_file
    tmp_file="$(mktemp "$(dirname "${SECRET_FILE}")/.env.local.XXXXXX")"
    awk '!/^GRAFANA_TOKEN=/' "${SECRET_FILE}" > "${tmp_file}"
    printf 'GRAFANA_TOKEN=%q\n' "${token}" >> "${tmp_file}"
    chmod 600 "${tmp_file}"
    mv "${tmp_file}" "${SECRET_FILE}"
}

configure() {
    local account_id token seconds
    : "${GRAFANA_ADMIN_PASSWORD:?GRAFANA_ADMIN_PASSWORD не задан в ${ENV_FILE}}"
    seconds="$(ttl_seconds "${TTL}")"

    account_id="$(curl -sf --max-time 5 -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
        "${GRAFANA_API_BASE}/api/serviceaccounts/search?perpage=1000&query=${SERVICE_ACCOUNT_NAME}" \
        | jq -r --arg name "${SERVICE_ACCOUNT_NAME}" \
            '.serviceAccounts[]? | select(.name == $name) | .id' \
        | head -1)"

    if [[ -z "${account_id}" ]]; then
        account_id="$(curl -sf --max-time 5 -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
            -H 'Content-Type: application/json' \
            -d "{\"name\":\"${SERVICE_ACCOUNT_NAME}\",\"role\":\"Editor\"}" \
            "${GRAFANA_API_BASE}/api/serviceaccounts" | jq -r '.id')"
    fi
    [[ "${account_id}" =~ ^[0-9]+$ ]] || {
        echo "Grafana не вернула id service account" >&2
        return 1
    }

    token="$(curl -sf --max-time 5 -u "admin:${GRAFANA_ADMIN_PASSWORD}" \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"chaos-$(date -u +%Y%m%dT%H%M%SZ)\",\"secondsToLive\":${seconds}}" \
        "${GRAFANA_API_BASE}/api/serviceaccounts/${account_id}/tokens" | jq -r '.key')"
    [[ -n "${token}" && "${token}" != null ]] || {
        echo "Grafana не вернула токен" >&2
        return 1
    }

    store_token "${token}"
    echo "Service account ${SERVICE_ACCOUNT_NAME} (Editor): токен сохранён в ${SECRET_FILE}, TTL=${TTL}"
}

test_annotation() {
    check_token >/dev/null
    # shellcheck source=../lib/grafana.sh
    source "${REPO_DIR}/lib/grafana.sh"
    local test_name="workshop-integration-check"
    export CHAOS_DRY_RUN=true
    grafana_region_open "${test_name}" "Проверка аннотаций без chaos-воздействия" control
    sleep 1
    grafana_region_close "${test_name}"

    local count
    count="$(curl -sf --max-time 5 \
        -H "Authorization: Bearer ${GRAFANA_TOKEN}" \
        "${GRAFANA_API_BASE}/api/annotations?tags=chaos-dry&limit=100" \
        | jq --arg tag "${test_name}" \
            '[.[] | select(.tags | index($tag))] | length')"
    [[ "${count}" -ge 1 ]] || {
        echo "Тестовая аннотация не найдена" >&2
        return 1
    }
    echo "Тестовая START/END-аннотация: OK"
}

case "${MODE}" in
    configure) configure ;;
    check) check_token ;;
    test) test_annotation ;;
esac
