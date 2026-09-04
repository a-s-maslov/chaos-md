#!/usr/bin/env bash
# Немезис: смена GPT partition name (partlabel) через sgdisk + partx -u.
# Эмуляция «не того» диска для YDB без выдёргивания устройства из ядра.
#
# Ожидаются пакеты gdisk на хосте (prepare-hosts ставит gdisk).
#
# Переменные окружения (после source env):
#   CHAOS_DISK_PARTNUM        номер партиции (по умолчанию 1)
#   CHAOS_DISK_LABEL_CHAOS    метка во время хаоса (по умолчанию test)
#   CHAOS_DISK_LABEL_NORMAL   рабочая метка (по умолчанию ydb_disk_ssd_01)
#
# API:
#   nemesis_disk_apply    <host> <device> <timeout_s>   # device: vdb или /dev/vdb
#   nemesis_disk_teardown <host> <device>
#   nemesis_disk_check    <host> <device>

nemesis_disk_part_suffix() {
    local device="$1" part="$2"
    if [[ "${device}" =~ [0-9]$ ]]; then
        printf '%sp%s' "${device}" "${part}"
    else
        printf '%s%s' "${device}" "${part}"
    fi
}

nemesis_disk_apply() {
    local host="$1" device="$2" timeout_s="$3"
    device="${device#/dev/}"
    local part="${CHAOS_DISK_PARTNUM:-1}"
    local lab_off="${CHAOS_DISK_LABEL_CHAOS:-test}"
    local lab_on="${CHAOS_DISK_LABEL_NORMAL:-ydb_disk_ssd_01}"
    local chg_off disk_q part_q expected_q state_label_q state_pid_q state_recover_q

    chg_off=$(printf '%q' "${part}:${lab_off}")
    disk_q=$(printf '%q' "/dev/${device}")
    part_q=$(printf '%q' "/dev/$(nemesis_disk_part_suffix "${device}" "${part}")")
    expected_q=$(printf '%q' "${lab_on}")
    state_label_q=$(printf '%q' "/tmp/disk-chaos-${device}-${part}.label")
    state_pid_q=$(printf '%q' "/tmp/disk-chaos-${device}-${part}.pid")
    state_recover_q=$(printf '%q' "/tmp/disk-chaos-${device}-${part}-recover.sh")

    log_chaos_apply "sgdisk partlabel ${lab_off} на ${host} ${disk_q}, авто-возврат исходной метки через ${timeout_s}s"
    chaos_term_remote_cmd "ssh ${host}  sgdisk -c … + partx -u + timer restore"

    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [[ ! -b ${disk_q} ]]; then
    echo "ОШИБКА: блочное устройство ${disk_q} не найдено" >&2
    exit 1
fi
command -v sgdisk >/dev/null 2>&1 || { echo "ОШИБКА: нет sgdisk (apt install gdisk / prepare-hosts)" >&2; exit 1; }
if [[ ! -b ${part_q} ]]; then
    echo "ОШИБКА: раздел ${part_q} не найден" >&2
    exit 1
fi
if [[ -f ${state_pid_q} || -f ${state_label_q} ]]; then
    echo "ОШИБКА: для ${part_q} уже есть незавершённое состояние disk chaos" >&2
    exit 1
fi
if lsblk -dnro MOUNTPOINTS ${part_q} | grep -q '[^[:space:]]'; then
    echo "ОШИБКА: ${part_q} смонтирован; разрешён только raw-диск YDB" >&2
    exit 1
fi
original_label="\$(lsblk -dnro PARTLABEL ${part_q} | tr -d '[:space:]')"
if [[ -z "\${original_label}" ]]; then
    echo "ОШИБКА: у ${part_q} нет исходной GPT partlabel" >&2
    exit 1
fi
if [[ -n ${expected_q} && "\${original_label}" != ${expected_q} ]]; then
    echo "ОШИБКА: метка ${part_q} = \${original_label}, ожидалась ${expected_q}" >&2
    exit 1
fi
printf '%s\n' "\${original_label}" > ${state_label_q}
sudo sgdisk -c ${chg_off} ${disk_q}
sudo partx -u ${disk_q}
cat > ${state_recover_q} <<'RECOVERY'
#!/usr/bin/env bash
set -euo pipefail
sleep ${timeout_s}
restore_label="\$(cat ${state_label_q})"
sudo sgdisk -c "${part}:\${restore_label}" ${disk_q}
sudo partx -u ${disk_q}
rm -f ${state_label_q} ${state_pid_q} ${state_recover_q}
RECOVERY
chmod 700 ${state_recover_q}
nohup bash ${state_recover_q} >/tmp/disk-chaos.log 2>&1 &
echo \$! > ${state_pid_q}
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт disk sgdisk, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
}

nemesis_disk_teardown() {
    local host="$1" device="$2"
    device="${device#/dev/}"
    local part="${CHAOS_DISK_PARTNUM:-1}"
    local lab_on="${CHAOS_DISK_LABEL_NORMAL:-ydb_disk_ssd_01}"
    local disk_q state_label_q state_pid_q state_recover_q
    disk_q=$(printf '%q' "/dev/${device}")
    state_label_q=$(printf '%q' "/tmp/disk-chaos-${device}-${part}.label")
    state_pid_q=$(printf '%q' "/tmp/disk-chaos-${device}-${part}.pid")
    state_recover_q=$(printf '%q' "/tmp/disk-chaos-${device}-${part}-recover.sh")

    chaos_term_remote_cmd "ssh ${host}  kill disk timer + sgdisk restore ${lab_on}"
    local remote_script
    remote_script=$(cat <<REMOTE
set -euo pipefail
if [[ -f ${state_pid_q} ]]; then
    kill "\$(cat ${state_pid_q})" 2>/dev/null || true
    rm -f ${state_pid_q}
fi
if [[ -b ${disk_q} ]] && command -v sgdisk >/dev/null 2>&1; then
    restore_label=$(printf '%q' "${lab_on}")
    [[ ! -f ${state_label_q} ]] || restore_label="\$(cat ${state_label_q})"
    [[ -n "\${restore_label}" ]] || { echo "ОШИБКА: неизвестна метка для восстановления" >&2; exit 1; }
    sudo sgdisk -c "${part}:\${restore_label}" ${disk_q}
    sudo partx -u ${disk_q}
    rm -f ${state_label_q} ${state_recover_q}
fi
REMOTE
)
    chaos_log_remote_script "Удалённый скрипт disk teardown, хост ${host}" "${remote_script}"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<<"${remote_script}"
    log "Метка партиции восстановлена на ${host} (${lab_on})"
}

nemesis_disk_check() {
    local host="$1" device="$2"
    device="${device#/dev/}"
    local part="${CHAOS_DISK_PARTNUM:-1}"
    local lab_off="${CHAOS_DISK_LABEL_CHAOS:-test}"
    local lab_on="${CHAOS_DISK_LABEL_NORMAL:-ydb_disk_ssd_01}"
    local psuffix
    psuffix="$(nemesis_disk_part_suffix "${device}" "${part}")"

    chaos_term_remote_cmd "ssh ${host}  lsblk + by-partlabel"
    ssh "${SSH_OPTS[@]}" "${host}" "bash -s" <<REMOTE
echo "=== /dev/${device} ==="
if [[ -b /dev/${device} ]]; then
    lsblk "/dev/${device}" 2>/dev/null || true
    if [[ -b /dev/${psuffix} ]]; then
        echo "=== partition /dev/${psuffix} ==="
        lsblk "/dev/${psuffix}" 2>/dev/null || true
    fi
else
    echo "  устройство отсутствует"
fi
echo "=== /dev/disk/by-partlabel/ (${lab_off} / ${lab_on}) ==="
ls -l "/dev/disk/by-partlabel/${lab_off}" 2>/dev/null || echo "  нет ${lab_off}"
ls -l "/dev/disk/by-partlabel/${lab_on}" 2>/dev/null || echo "  нет ${lab_on}"
REMOTE
}
