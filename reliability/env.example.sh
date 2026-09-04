#!/usr/bin/env bash
# Локальные параметры отказов конкретного стенда.
# Скопируйте в reliability/env.local.sh; файл исключён из Git.

YDBD_STORAGE_SERVICE="ydbd-storage.service"
YDBD_TENANT_SERVICES=(ydbd-database-a.service)
DEFAULT_YDBD_BIN="/opt/ydb/bin/ydbd"

# Выбирайте только отдельный raw-диск YDB после проверки `03-disk-fail.sh -C`.
DEFAULT_DISK_DEVICE="vdb"
CHAOS_DISK_PARTNUM=1
CHAOS_DISK_LABEL_NORMAL="ydb_disk_1"
CHAOS_DISK_LABEL_CHAOS="chaos_ydb_disk_1"
CHAOS_DISK_RESTART_STORAGE=true
