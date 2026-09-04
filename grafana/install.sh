#!/usr/bin/env bash
# Полная установка стека мониторинга: VictoriaMetrics + node_exporter + Grafana.
# Последовательно запускает 01-04 скрипты, останавливаясь после каждого шага.
#
# Запускать НА ${MON_HOST} ${MON_HOST} после sync-to-remote.sh.
# Поддерживается Ubuntu 24 (Noble).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${REPO_DIR}/lib/config.sh"
chaos_load_env "${REPO_DIR}"
source "${REPO_DIR}/lib/term.sh"

DRY_RUN="${CHAOS_DRY_RUN:-false}"
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        -h|--help)
            echo "Использование: $(basename "$0") [--dry-run]"
            echo "  Проверяет зависимости, выводит параметры, запускает 01→04 с паузами."
            exit 0 ;;
    esac
done
export CHAOS_DRY_RUN="${DRY_RUN}"

if [[ -n "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
    GRAFANA_ADMIN_PASSWORD_STATUS="configured"
else
    GRAFANA_ADMIN_PASSWORD_STATUS="not configured (default: admin)"
fi

_sep() { printf '%0.s─' {1..60}; printf '\n'; }

# ── Параметры ──────────────────────────────────────────────────────────────────
_sep
printf '%bПараметры установки%b\n' "${C_HOST}" "${C_RESET}"
_sep
cat <<EOF
  MON_HOST                  ${MON_HOST}
  CLUSTER_HOSTS             ${CLUSTER_HOSTS[*]}

  [VictoriaMetrics]
  VICTORIA_DOCKER_IMAGE     ${VICTORIA_DOCKER_IMAGE}
  VM_DATA_DIR               ${VM_DATA_DIR}
  VM_PORT                   ${VM_PORT}
  VM_RETENTION              ${VM_RETENTION}
  Scrape: node_exporter     ${CLUSTER_HOSTS[*]/%/:${NODE_EXPORTER_PORT}}
  Scrape: ydb               все ${CLUSTER_HOSTS[*]} × порты ${YDB_MON_PORTS} (см. grafana/scrape.yml)

  [node_exporter]
  NODE_EXPORTER_VERSION     ${NODE_EXPORTER_VERSION}
  NODE_EXPORTER_PORT        ${NODE_EXPORTER_PORT}

  [Grafana]
  GRAFANA_DOCKER_IMAGE      ${GRAFANA_DOCKER_IMAGE}
  GRAFANA_DATA_DIR          ${GRAFANA_DATA_DIR}
  GRAFANA_PORT              ${GRAFANA_PORT}
  Admin password            ${GRAFANA_ADMIN_PASSWORD_STATUS}
  Provisioning dir          ${SCRIPT_DIR}/provisioning
  Dashboards dir            ${SCRIPT_DIR}/dashboards

  [Grafana API / аннотации]
  GRAFANA_URL               ${GRAFANA_URL:-  (не задан — аннотации отключены)}
  GRAFANA_TOKEN             ${GRAFANA_TOKEN:+(задан)}${GRAFANA_TOKEN:-  (не задан)}
EOF
if [[ "${DRY_RUN}" == "true" ]]; then
    printf '\n%b  DRY-RUN: команды будут напечатаны, но не выполнены%b\n' "${C_TIMER}" "${C_RESET}"
fi
_sep

# ── Подтверждение ──────────────────────────────────────────────────────────────
printf '\n%bПроверьте конфигурацию. Продолжить?: %b' "${C_HOST}" "${C_RESET}"
read -r -n1 ans
printf '\n'
if [[ "${ans}" != "Y" ]]; then
    echo "Отменено."
    exit 1
fi

# ── Проверка и установка зависимостей ─────────────────────────────────────────
printf '\n%bПроверка зависимостей%b\n' "${C_HOST}" "${C_RESET}"

# Docker
if command -v docker &>/dev/null; then
    DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ,)
    echo "  docker: ${DOCKER_VER}"
else
    echo "  docker не найден — устанавливаем..."

    if [[ "${DRY_RUN}" == "true" ]]; then
        printf '  %b  dry-run: установка docker пропущена%b\n' "${C_TIMER}" "${C_RESET}"
    else
        sudo apt-get update -qq
        sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release

        sudo install -m 0755 -d /etc/apt/keyrings
        sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        sudo chmod a+r /etc/apt/keyrings/docker.asc

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME}}") stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

        sudo apt-get update -qq
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin

        sudo systemctl enable --now docker
        sudo usermod -aG docker "${USER}"

        DOCKER_VER=$(docker --version | awk '{print $3}' | tr -d ,)
        echo "  docker ${DOCKER_VER} установлен"
        printf '  %bВНИМАНИЕ: добавлен в группу docker. Для вступления в силу — переподключитесь к хосту%b\n' \
            "${C_TIMER}" "${C_RESET}"
        printf '  %b  (или выполните: newgrp docker)%b\n' "${C_TIMER}" "${C_RESET}"
        echo "  Запускаем следующие docker-команды через sudo..."
        # Дальнейшие команды докера в этой сессии пройдут через sudo (group ещё не применена).
        # install-скрипты используют 'docker', которому нужен либо группа, либо sudo.
        # Переопределяем docker → sudo docker в текущей сессии.
        docker() { sudo docker "$@"; }
        export -f docker
    fi
fi
_sep

# ── Вспомогательная функция: запустить шаг и предложить продолжить ─────────────
run_step() {
    local num="$1" name="$2" script="$3"
    _sep
    printf '%b[%s] %s%b\n' "${C_HOST}" "${num}" "${name}" "${C_RESET}"
    _sep
    bash "${SCRIPT_DIR}/${script}"
    printf '\n%b[%s] %s завершён.%b\n' "${C_HOST}" "${num}" "${name}" "${C_RESET}"
    if [[ "${num}" != "04" ]]; then
        printf 'Нажмите Enter для следующего шага или Ctrl-C для выхода: '
        read -r
    fi
}

# ── Шаги ───────────────────────────────────────────────────────────────────────
run_step "01" "VictoriaMetrics"        "01-victoria.sh"
run_step "02" "node_exporter"          "02-node-exporter.sh"
run_step "03" "Grafana"                "03-grafana.sh"
run_step "04" "Dashboards / provision" "04-dashboards-provision.sh"

_sep
printf '%b✓ Установка завершена%b\n' "${C_HOST}" "${C_RESET}"
cat <<EOF

  Grafana:          http://${MON_HOST}:${GRAFANA_PORT}/
  VictoriaMetrics:  http://${MON_HOST}:${VM_PORT}/-/ready

  Снаружи лаба — SSH-туннель:
    ssh -L ${GRAFANA_PORT}:localhost:${GRAFANA_PORT} ${MON_HOST}
    ssh -L ${VM_PORT}:localhost:${VM_PORT} ${MON_HOST}
EOF
_sep
