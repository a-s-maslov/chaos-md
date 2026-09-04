#!/usr/bin/env bash
# Добавьте нужные значения в workload/env.local.sh (файл gitignored).

CHAOS_WORKLOAD_TYPE="search"
CHAOS_WORKLOAD_START_TIMEOUT=15
CHAOS_WORKLOAD_STOP_TIMEOUT=15

# На Ubuntu используйте binary; локально на Windows — compose + Podman.
SEARCH_WORKLOAD_MODE="binary"          # binary | compose
SEARCH_WORKLOAD_BIN="/opt/deep-tech-ydb-searches/bin/search-workload"
SEARCH_WORKLOAD_CONFIG="/opt/deep-tech-ydb-searches/config/workload.stand.json"
SEARCH_WORKLOAD_METRICS_URL="http://127.0.0.1:9091/metrics"

# Пример локального режима:
# SEARCH_WORKLOAD_MODE="compose"
# SEARCH_WORKLOAD_PROJECT_DIR="C:/path/to/deep-tech-ydb-searches"
# SEARCH_WORKLOAD_COMPOSE_FILE="compose.workload.yaml"
# SEARCH_WORKLOAD_CONTAINER_ENGINE="podman"
# Для локальной YDB в контейнере adapter сам определит её IP в указанной сети.
# Это обходит неоднозначное DNS-имя контейнера, подключённого к нескольким сетям.
# SEARCH_WORKLOAD_YDB_CONTAINER="workshop-ydb-smoke"
# SEARCH_WORKLOAD_YDB_NETWORK="chaos-monitoring"
# SEARCH_WORKLOAD_YDB_PORT=2136
# SEARCH_WORKLOAD_YDB_DATABASE="/local"
