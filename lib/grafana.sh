#!/usr/bin/env bash
# Аннотации Grafana — открытие/закрытие региональной аннотации на интервал хаоса.
# Без GRAFANA_URL / GRAFANA_TOKEN всё превращается в no-op.
#
# Используется через timeline.sh: log_tl CHAOS_START / CHAOS_END / CHAOS_CANCEL.
# ID открытой аннотации хранится в /tmp/grafana-chaos-<test_name>.id.

_grafana_time_ms() {
    if date +%s%3N 2>/dev/null | grep -q '^[0-9]\{13\}$'; then
        date +%s%3N
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c "import time; print(int(time.time()*1000))"
    else
        echo $(( $(date +%s) * 1000 ))
    fi
}

_grafana_id_file() {
    echo "/tmp/grafana-chaos-$1.id"
}

_grafana_json_text() {
    local text="$1" encoded python_cmd

    # jq/Python дают полное JSON-кодирование, но не являются обязательными.
    if command -v jq >/dev/null 2>&1; then
        printf '%s' "${text}" | jq -Rs .
        return
    fi

    for python_cmd in python3 python; do
        if command -v "${python_cmd}" >/dev/null 2>&1; then
            if encoded="$(printf '%s' "${text}" | "${python_cmd}" -c \
                'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null)"; then
                printf '%s' "${encoded}"
                return
            fi
        fi
    done

    # Достаточный fallback для управляемых строк timeline без внешних утилит.
    text=${text//\\/\\\\}
    text=${text//\"/\\\"}
    text=${text//$'\b'/\\b}
    text=${text//$'\f'/\\f}
    text=${text//$'\n'/\\n}
    text=${text//$'\r'/\\r}
    text=${text//$'\t'/\\t}
    printf '"%s"' "${text}"
}

# Открыть регион. Сохраняет id для дальнейшего close.
# Необязательный третий аргумент классифицирует событие для дашбордов:
# failure (default), workload или control. Базовый тег chaos сохраняется.
grafana_region_open() {
    local test_name="$1" text="$2" event_kind="${3:-failure}"
    [[ -z "${GRAFANA_URL:-}" ]] && return 0

    if [[ ! "${event_kind}" =~ ^[a-z0-9][a-z0-9_-]*$ ]]; then
        echo "grafana: WARNING invalid event kind (${event_kind}), using failure" >&2
        event_kind="failure"
    fi

    local time_ms id_file payload response annot_id
    time_ms="$(_grafana_time_ms)"
    id_file="$(_grafana_id_file "${test_name}")"
    local chaos_tag="chaos"
    [[ "${CHAOS_DRY_RUN:-false}" == "true" ]] && chaos_tag="chaos-dry"
    payload="$(printf '{"time":%s,"timeEnd":%s,"tags":["%s","event:%s","%s"],"text":%s}' \
        "${time_ms}" "${time_ms}" "${chaos_tag}" "${event_kind}" "${test_name}" "$(_grafana_json_text "${text}")")"

    response=$(curl -sfk --max-time 5 \
        -XPOST "${GRAFANA_URL}/api/annotations" \
        -H "Authorization: Bearer ${GRAFANA_TOKEN:-}" \
        -H "Content-Type: application/json" \
        -d "${payload}" 2>&1) || {
        echo "grafana: WARNING POST failed (${test_name})" >&2
        return 0
    }
    annot_id=$(echo "${response}" | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
    [[ -n "${annot_id}" ]] && echo "${annot_id}" > "${id_file}"
}

# Закрыть регион.
grafana_region_close() {
    local test_name="$1"
    [[ -z "${GRAFANA_URL:-}" ]] && return 0

    local id_file annot_id time_end
    id_file="$(_grafana_id_file "${test_name}")"
    [[ -f "${id_file}" ]] || return 0
    annot_id=$(cat "${id_file}"); rm -f "${id_file}"
    [[ -z "${annot_id}" ]] && return 0

    time_end="$(_grafana_time_ms)"
    curl -sfk --max-time 5 \
        -XPATCH "${GRAFANA_URL}/api/annotations/${annot_id}" \
        -H "Authorization: Bearer ${GRAFANA_TOKEN:-}" \
        -H "Content-Type: application/json" \
        -d "{\"timeEnd\": ${time_end}}" >/dev/null 2>&1 || {
        echo "grafana: WARNING PATCH failed id=${annot_id}" >&2
    }
}
