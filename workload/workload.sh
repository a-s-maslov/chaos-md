#!/usr/bin/env bash
# workload.sh — единый CLI модуля нагрузки YDB.
#
# Команды:
#   info               Показать конфигурацию.
#   init               Создать тестовые таблицы.
#   run [scenario...]  Запустить нагрузку (default: ${WL_SCENARIOS}).
#   cleanup            Удалить тестовые таблицы.
#
# Опции:
#   -d, --duration N      override WL_RUN_DURATION
#   -t, --threads N       override WL_RUN_THREADS
#   -y, --yes             без подтверждения для cleanup
#   -n, --dry-run         печатать ydb-команды и не выполнять
#   -h, --help            справка
#
# Метрики уходят в VictoriaMetrics (если задан WL_VM_WRITE_URL),
# в схеме ydb_workload_* с тегами application, scenario, statut.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"
# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=lib/ydb.sh
source "${SCRIPT_DIR}/lib/ydb.sh"
# shellcheck source=lib/vm.sh
source "${SCRIPT_DIR}/lib/vm.sh"
# shellcheck source=lib/stats.sh
source "${SCRIPT_DIR}/lib/stats.sh"

WL_DRY_RUN="${WL_DRY_RUN:-false}"

usage() {
    cat <<EOF
Использование: $(basename "$0") <command> [opts]

Commands:
  info               Показать конфигурацию.
  init               Создать тестовые таблицы.
  run [scenario...]  Запустить нагрузку (default: \${WL_SCENARIOS}).
  cleanup            Удалить тестовые таблицы.
  help               Показать справку.

Опции:
  -d, --duration N      override WL_RUN_DURATION (для run)
  -t, --threads N       override WL_RUN_THREADS  (для run)
  -y, --yes             без подтверждения для cleanup
  -n, --dry-run         печатать команды и выйти
  -h, --help            эта справка

Текущий target:
  YDB_PROFILE  : ${WL_YDB_PROFILE:-(не задан)}
  YDB_ENDPOINT : ${WL_YDB_ENDPOINT:-(не задан)}
  YDB_DATABASE : ${WL_YDB_DATABASE:-(не задан)}
  VM_WRITE_URL : ${WL_VM_WRITE_URL:-(не задан, метрики только в лог)}
EOF
}

# === Парсинг общих опций ===
COMMAND=""
SCENARIOS_ARG=()
ASSUME_YES=false

_parse_opts() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -d|--duration) WL_RUN_DURATION="$2"; shift 2 ;;
            -t|--threads)  WL_RUN_THREADS="$2";  shift 2 ;;
            -y|--yes)      ASSUME_YES=true; shift ;;
            -n|--dry-run)  WL_DRY_RUN=true; shift ;;
            -h|--help)     usage; exit 0 ;;
            --) shift; SCENARIOS_ARG+=("$@"); break ;;
            -*) die "Неизвестная опция: $1" ;;
            *)  SCENARIOS_ARG+=("$1"); shift ;;
        esac
    done
}

[[ $# -gt 0 ]] || { usage; exit 0; }
COMMAND="$1"; shift
_parse_opts "$@"

# === info ===
cmd_info() {
    log_section "Конфигурация workload"
    log_info "REMOTE_HOST  = ${WL_REMOTE_HOST:-(не задан)}"
    log_info "REMOTE_USER  = ${WL_REMOTE_USER}"
    log_info "REMOTE_DEST  = ${WL_REMOTE_DEST}"
    log_info "YDB_PROFILE  = ${WL_YDB_PROFILE:-(не задан)}"
    log_info "YDB_ENDPOINT = ${WL_YDB_ENDPOINT:-(не задан)}"
    log_info "YDB_DATABASE = ${WL_YDB_DATABASE:-(не задан)}"
    log_info "VM_WRITE_URL = ${WL_VM_WRITE_URL:-(не задан, метрики только в лог)}"
    log_info "APPLICATION  = ${WL_APPLICATION}"
    log_info "INIT         = products=${WL_INIT_PRODUCTS} quantity=${WL_INIT_QUANTITY} orders=${WL_INIT_ORDERS} min-partitions=${WL_INIT_MIN_PARTITIONS}"
    log_info "RUN          = threads=${WL_RUN_THREADS} duration=${WL_RUN_DURATION}s window=${WL_RUN_WINDOW}s rate=${WL_RUN_RATE:-none}"
    log_info "SCENARIOS    = ${WL_SCENARIOS}"
    log_info "LOG_DIR      = ${WL_LOG_DIR}"
}

# === init ===
cmd_init() {
    ydb_require_target
    log_section "init: создание тестовых таблиц"

    log_info "Запускаю ydb workload stock init…"
    ydb_run workload stock init \
        --products       "${WL_INIT_PRODUCTS}" \
        --quantity       "${WL_INIT_QUANTITY}" \
        --orders         "${WL_INIT_ORDERS}" \
        --min-partitions "${WL_INIT_MIN_PARTITIONS}" \
        --auto-partition "${WL_INIT_AUTO_PARTITION}"

    if [[ "${WL_DRY_RUN}" != "true" ]]; then
        cat > "${SCRIPT_DIR}/init.json" <<EOF
{
  "ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "products": ${WL_INIT_PRODUCTS},
  "quantity": ${WL_INIT_QUANTITY},
  "orders": ${WL_INIT_ORDERS},
  "min_partitions": ${WL_INIT_MIN_PARTITIONS},
  "auto_partition": ${WL_INIT_AUTO_PARTITION}
}
EOF
        log_info "Аудит: ${SCRIPT_DIR}/init.json"
    fi
    log_section "init: готово"
}

# === cleanup ===
cmd_cleanup() {
    ydb_require_target
    log_section "cleanup: удаление тестовых таблиц"

    if [[ "${ASSUME_YES}" != "true" ]]; then
        printf 'Удалить тестовые таблицы workload stock? Введите "yes" для подтверждения: '
        local answer; read -r answer
        [[ "${answer}" == "yes" ]] || { log_warn "Отменено пользователем"; exit 1; }
    fi

    log_info "Запускаю ydb workload stock clean…"
    ydb_run workload stock clean || {
        log_warn "clean вернул ошибку (возможно, таблицы не существуют) — продолжаем"
    }
    log_section "cleanup: готово"
}

# === run ===
_run_scenario() {
    local scenario="$1"

    local args=(workload stock run "${scenario}"
                -s "${WL_RUN_DURATION}"
                -t "${WL_RUN_THREADS}"
                --window "${WL_RUN_WINDOW}"
                --print-timestamp
                --client-timeout    "${WL_RUN_CLIENT_TIMEOUT_MS}"
                --operation-timeout "${WL_RUN_OPERATION_TIMEOUT_MS}")
    [[ -n "${WL_RUN_RATE:-}" ]] && args+=(--rate "${WL_RUN_RATE}")

    log_info "[${scenario}] стартую (pid $$); duration=${WL_RUN_DURATION}s threads=${WL_RUN_THREADS}"
    if [[ "${WL_DRY_RUN}" == "true" ]]; then
        ydb_run "${args[@]}"
        return 0
    fi
    ydb_run "${args[@]}" 2>&1 | stats_pipe_to_vm "${scenario}"
}

cmd_run() {
    ydb_require_target

    local scenarios=()
    if [[ "${#SCENARIOS_ARG[@]}" -gt 0 ]]; then
        scenarios=("${SCENARIOS_ARG[@]}")
    else
        # shellcheck disable=SC2206
        scenarios=(${WL_SCENARIOS})
    fi
    [[ "${#scenarios[@]}" -gt 0 ]] || die "Не указаны сценарии (WL_SCENARIOS пуст и нет позиционных аргументов)"

    [[ -z "${WL_VM_WRITE_URL:-}" ]] && log_warn "WL_VM_WRITE_URL пуст — метрики не пушатся в VictoriaMetrics, только в локальный лог"

    local run_id; run_id="$(date +%Y%m%dT%H%M%S)-$$"
    mkdir -p "${WL_LOG_DIR}"
    local main_log="${WL_LOG_DIR}/run-${run_id}.log"
    WL_LOG_FILE="${main_log}"
    export WL_LOG_FILE

    log_section "run: ${run_id}"
    log_info "Лог: ${main_log}"
    log_info "Сценарии: ${scenarios[*]}"
    log_info "Нагрузка: threads=${WL_RUN_THREADS} duration=${WL_RUN_DURATION}s window=${WL_RUN_WINDOW}s rate=${WL_RUN_RATE:-unlimited}"

    local pids=()
    local sc
    for sc in "${scenarios[@]}"; do
        local sc_log="${WL_LOG_DIR}/run-${run_id}-${sc}.log"
        log_info "[${sc}] log: ${sc_log}"
        ( _run_scenario "${sc}" ) >>"${sc_log}" 2>&1 &
        pids+=($!)
    done

    _wl_kill_kids() {
        log_warn "Получен сигнал — гашу дочерние процессы…"
        local p
        for p in "${pids[@]:-}"; do
            kill "${p}" 2>/dev/null || true
        done
        wait "${pids[@]:-}" 2>/dev/null || true
        log_section "run: остановлен"
        exit 130
    }
    trap _wl_kill_kids INT TERM

    local rc=0 p
    for p in "${pids[@]}"; do
        wait "${p}" || rc=$?
    done
    trap - INT TERM

    if [[ "${rc}" -ne 0 ]]; then
        log_err "Один или несколько сценариев завершились с ошибкой (последний rc=${rc})"
        exit "${rc}"
    fi
    log_section "run: завершён (${run_id})"
}

case "${COMMAND}" in
    info)    cmd_info ;;
    init)    cmd_init ;;
    run)     cmd_run ;;
    cleanup) cmd_cleanup ;;
    help|-h|--help) usage ;;
    *) usage; die "Неизвестная команда: ${COMMAND}" ;;
esac
