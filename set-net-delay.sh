#!/usr/bin/env bash
# Задержка netem на корневом qdisc интерфейса (весь трафик, без фильтра по портам).
# Простая утилита для отладки сети — без timeline, Grafana и фонового таймера автоснятия.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/lib/config.sh"
chaos_load_env "${SCRIPT_DIR}"
# shellcheck source=lib/net.sh
source "${SCRIPT_DIR}/lib/net.sh"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/term.sh
source "${SCRIPT_DIR}/lib/term.sh"

DELAY="${DEFAULT_NET_DELAY}"
DESTROY_MODE=false
CHECK_HOST=""
NODE_HOST="${SINGLE_HOST}"
SCOPE_SINGLE=false
SCOPE_DC=false

usage() {
    cat <<EOF
Использование: $(basename "$0") -1|-4 [ОПЦИИ]

Задержка netem на корне qdisc — весь исходящий трафик на интерфейсах из NET_IFACES / NET_IFACES_TABLE (lib/net.sh).
Без timeline.log и Grafana. Снятие только вручную: -D.

  -1, --single          Одна нода (-H или ${SINGLE_HOST})
  -4, --dc              Весь ДЦ (DC_HOSTS)
  -d, --delay MS        Задержка, мс (по умолчанию: ${DEFAULT_NET_DELAY})
  -H, --host HOST       Хост для -1
  -C [HOST]             Показать tc qdisc на интерфейсе
  -D, --teardown        Снять netem с ноды и ДЦ
  -h, --help            Справка
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--delay)    DELAY="$2"; shift 2 ;;
        -H|--host)     NODE_HOST="$2"; shift 2 ;;
        -1|--single)   SCOPE_SINGLE=true; shift ;;
        -4|--dc)       SCOPE_DC=true;     shift ;;
        -C|--check)
            CHECK_HOST="${SINGLE_HOST}"
            if [[ $# -gt 1 && "$2" != -* ]]; then CHECK_HOST="$2"; shift; fi
            shift ;;
        -D|--teardown|--destroy) DESTROY_MODE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 1 ;;
    esac
done

_tc_show_remote() {
    local host="$1" iface
    chaos_net_ifaces_for_host "${host}"
    chaos_term_target "=== ${host} (${CHAOS_NET_IFACES_ARR[*]}) ==="
    for iface in "${CHAOS_NET_IFACES_ARR[@]}"; do
        chaos_term_remote_cmd "ssh ${host}  tc qdisc/class show dev ${iface}"
        ssh "${SSH_OPTS[@]}" "${host}" "
            echo '--- tc qdisc dev=${iface} ---'; sudo tc qdisc show dev ${iface} 2>/dev/null || true
            echo '--- tc class dev=${iface} ---'; sudo tc class show dev ${iface} 2>/dev/null || true
        "
    done
}

_tc_apply_host() {
    local host="$1" iface qi qd
    chaos_net_ifaces_for_host "${host}"
    qd=$(printf '%q' "${DELAY}")
    for iface in "${CHAOS_NET_IFACES_ARR[@]}"; do
        qi=$(printf '%q' "${iface}")
        chaos_term_remote_cmd "ssh ${host}  tc qdisc replace dev ${iface} root netem delay ${DELAY}ms"
        local remote_script
        remote_script=$(cat <<REMOTE
set -euo pipefail
_iface=${qi}; _delay_ms=${qd}
sudo tc qdisc del dev "\${_iface}" root 2>/dev/null || true
sudo tc qdisc add dev "\${_iface}" root netem delay \${_delay_ms}ms limit 262144
REMOTE
)
        chaos_log_remote_script "Удалённый скрипт set-net-delay apply, ${host} dev=${iface}" "${remote_script}"
        ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
    done
}

_tc_remove_host() {
    local host="$1" iface qi
    chaos_net_ifaces_for_host "${host}"
    for iface in "${CHAOS_NET_IFACES_ARR[@]}"; do
        qi=$(printf '%q' "${iface}")
        chaos_term_remote_cmd "ssh ${host}  tc qdisc del dev ${iface} root"
        local remote_script
        remote_script=$(cat <<REMOTE
set -euo pipefail
_iface=${qi}
sudo tc qdisc del dev "\${_iface}" root 2>/dev/null || true
REMOTE
)
        chaos_log_remote_script "Удалённый скрипт set-net-delay teardown, ${host} dev=${iface}" "${remote_script}"
        ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
    done
}

if [[ -n "${CHECK_HOST}" ]]; then
    _tc_show_remote "${CHECK_HOST}"
    exit 0
fi

if [[ "${DESTROY_MODE}" == true ]]; then
    _tc_remove_host "${NODE_HOST}"
    for h in "${DC_HOSTS[@]}"; do _tc_remove_host "${h}" & done
    wait || true
    exit 0
fi

if [[ "${SCOPE_SINGLE}" != true && "${SCOPE_DC}" != true ]]; then
    echo "Ошибка: укажите -1 или -4." >&2; usage >&2; exit 1
fi
if [[ "${SCOPE_SINGLE}" == true && "${SCOPE_DC}" == true ]]; then
    echo "Ошибка: нельзя одновременно -1 и -4." >&2; exit 1
fi

if [[ "${SCOPE_SINGLE}" == true ]]; then
    chaos_net_ifaces_for_host "${NODE_HOST}"
    chaos_term_target "set-net-delay: ${NODE_HOST}  delay=${DELAY}ms  ifaces=${CHAOS_NET_IFACES_ARR[*]}  (снять: -D)"
    _tc_apply_host "${NODE_HOST}"
    exit 0
fi

chaos_term_target "set-net-delay: ДЦ (${#DC_HOSTS[@]} хостов)  delay=${DELAY}ms  (снять: -D)"
for h in "${DC_HOSTS[@]}"; do _tc_apply_host "${h}" & done
wait || true
