#!/usr/bin/env bash
# Синхронизация каталога проекта на удалённый хост (rsync → ~/${RSYNC_DEST}).
# Хост и каталог берутся из env.sh (переменные RSYNC_HOST, RSYNC_DEST), либо
# переопределяются через CHAOS_RSYNC_HOST / CHAOS_RSYNC_DEST в окружении.
#
# Запуск и уход с площадки после завершения:
#   ./sync-to-remote.sh
#   nohup ./sync-to-remote.sh >~/sync-chaos-tests.log 2>&1 &
#   ./sync-to-remote.sh -b
#
# Переменные окружения (опционально):
#   CHAOS_RSYNC_HOST   хост (по умолчанию RSYNC_HOST из env.sh)
#   CHAOS_RSYNC_USER   пользователь SSH; пусто = использовать ssh-алиас как есть
#   CHAOS_RSYNC_DEST   каталог на сервере относительно домашней (по умолчанию RSYNC_DEST)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/lib/config.sh"
chaos_load_env "${SCRIPT_DIR}"

CHAOS_RSYNC_HOST="${CHAOS_RSYNC_HOST:-${RSYNC_HOST:-}}"
CHAOS_RSYNC_USER="${CHAOS_RSYNC_USER:-}"
CHAOS_RSYNC_DEST="${CHAOS_RSYNC_DEST:-${RSYNC_DEST:-disarray}}"

if [[ -z "${CHAOS_RSYNC_HOST}" ]]; then
    echo "Ошибка: RSYNC_HOST не задан в env.sh и не передан через CHAOS_RSYNC_HOST" >&2
    exit 1
fi

DRY_RUN=false
BACKGROUND=false
DELETE_REMOTE_EXTRA=false

# Если CHAOS_RSYNC_HOST уже содержит user@host или CHAOS_RSYNC_USER пуст —
# не префиксуем ничего (ssh-алиас в ~/.ssh/config сам определит пользователя).
if [[ "${CHAOS_RSYNC_HOST}" == *"@"* || -z "${CHAOS_RSYNC_USER}" ]]; then
    REMOTE_TARGET="${CHAOS_RSYNC_HOST}"
else
    REMOTE_TARGET="${CHAOS_RSYNC_USER}@${CHAOS_RSYNC_HOST}"
fi

usage() {
    cat <<EOF
Использование: $(basename "$0") [ОПЦИИ]

rsync каталога проекта (как есть, со всеми файлами) на сервер.

  ${REMOTE_TARGET}:~/${CHAOS_RSYNC_DEST}/

Опции:
  -n, --dry-run   Только показать, что бы изменилось
  --delete        Удалить на сервере файлы, которых нет локально (осторожно)
  -b, --background  Запустить себя через nohup, вывести PID и выйти
  -h, --help      Справка

Переменные: CHAOS_RSYNC_HOST, CHAOS_RSYNC_USER, CHAOS_RSYNC_DEST.
По умолчанию читаются из env.sh: RSYNC_HOST=${RSYNC_HOST:-?}, RSYNC_DEST=${RSYNC_DEST:-?}.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)  DRY_RUN=true; shift ;;
        --delete)      DELETE_REMOTE_EXTRA=true; shift ;;
        -b|--background) BACKGROUND=true; shift ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 1 ;;
    esac
done

REMOTE="${REMOTE_TARGET}:~/${CHAOS_RSYNC_DEST}/"
LOG_FILE="${HOME}/sync-chaos-tests.$(date +%Y%m%d-%H%M%S).log"

if [[ "${BACKGROUND}" == true ]]; then
    _bg_args=()
    [[ "${DRY_RUN}" == true ]] && _bg_args+=(--dry-run)
    [[ "${DELETE_REMOTE_EXTRA}" == true ]] && _bg_args+=(--delete)
    echo "Фон: лог ${LOG_FILE}"
    nohup env CHAOS_RSYNC_HOST="${CHAOS_RSYNC_HOST}" CHAOS_RSYNC_USER="${CHAOS_RSYNC_USER}" CHAOS_RSYNC_DEST="${CHAOS_RSYNC_DEST}" \
        bash "${SELF_PATH}" "${_bg_args[@]}" >>"${LOG_FILE}" 2>&1 &
    echo "PID $!"
    exit 0
fi

RSYNC_ARGS=(
    -a
    -v
    -z
    --partial
    --progress
    --exclude '.*'
    --exclude 'private'
    --exclude 'logs/*'
    --exclude 'chaos-md/target'
    --exclude '__pycache__'
    --exclude '.venv-*'
    -e "ssh ${SSH_OPTS[*]}"
)

[[ "${DRY_RUN}" == true ]] && RSYNC_ARGS+=(-n)
[[ "${DELETE_REMOTE_EXTRA}" == true ]] && RSYNC_ARGS+=(--delete)

_ts() { date '+%Y-%m-%dT%H:%M:%S%z'; }

echo "[$(_ts)] rsync ${SCRIPT_DIR}/ → ${REMOTE}"

rsync "${RSYNC_ARGS[@]}" "${SCRIPT_DIR}/" "${REMOTE}"

echo "[$(_ts)] готово"
