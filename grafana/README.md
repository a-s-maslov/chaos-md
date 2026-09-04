# grafana/ — мониторинг стенда

Установка и обслуживание стека **VictoriaMetrics + node_exporter + Grafana** для chaos-тестов.

---

## Назначение

| Компонент | Где живёт | Зачем |
|-----------|-----------|-------|
| **VictoriaMetrics** (single) | docker на `${MON_HOST}` | TSDB для метрик (vmsingle, scrape встроен) |
| **deep-tech-ydb-searches** | процесс на `${MON_HOST}` | клиентская поисковая нагрузка и endpoint метрик |
| **node_exporter** | systemd на `${CLUSTER_HOSTS[*]}` | системные метрики хостов (CPU, RAM, диск, сеть) |
| **Grafana** | docker на `${MON_HOST}` | визуализация + аннотации chaos-окон |

YDB-метрики со **всех** `CLUSTER_HOSTS` и **каждого** порта из `${YDB_MON_PORTS}` (список через запятую, по умолчанию `8765,8767,8768`) забирает встроенный scraper VictoriaMetrics по путям вида `/counters/counters=<имя>/prometheus` (см. `grafana/scrape.yml`). Job’ы **pdisks** и **vdisks** используют только `${YDB_MON_PD_PORT}` — порт мониторинга узла хранения (по умолчанию 8765); таргеты — в `ydbd-storage.yml` на стороне `MON_HOST`.

Аннотации хаос-окон (CHAOS_START / END) шлёт в Grafana `lib/grafana.sh` — это runtime-часть тестов, не часть установки.

Токен для аннотаций создаётся воспроизводимо и остаётся только локально:

```bash
# В env.local.sh заранее задайте GRAFANA_ADMIN_PASSWORD.
./grafana/configure-annotations.sh --env-file ./env.local.sh --ttl 30d
./grafana/configure-annotations.sh --env-file ./env.local.sh --check
./grafana/configure-annotations.sh --env-file ./env.local.sh --test
```

Скрипт создаёт или переиспользует service account `chaos-md` с ролью `Editor`,
выпускает токен с ограниченным сроком и записывает `GRAFANA_TOKEN` в указанный
gitignored env-файл. Сам токен в stdout не выводится. Если env-файл является
символической ссылкой, обновляется её целевой файл.

---

## Установка с нуля

Предусловие: на `${MON_HOST}` есть `docker`, на `${CLUSTER_HOSTS[*]}` доступен `sudo`.

С локальной машины делается так:

```bash
# 1) заливка репозитория на chaos-client (хост и каталог берутся из env.sh):
./sync-to-remote.sh

# 2) непосредственно на chaos-client:
ssh chaos-client
cd ~/${RSYNC_DEST:-chaos-tests}/grafana

# 3) далее друг за другом
./01-victoria.sh           # VictoriaMetrics в docker
./02-node-exporter.sh      # systemd-сервис на каждой ноде CLUSTER_HOSTS
./03-grafana.sh            # Grafana в docker (с маунтом provisioning/)
./04-dashboards-provision.sh   # рендер datasource yml + restart Grafana
```

Все скрипты поддерживают:
- `--check` — показать состояние (статус контейнера, метрики, файлы конфига).
- `--dry-run` — печатать команды, не выполнять.
- `-h, --help` — справка.

Скрипты `01-victoria.sh` и `03-grafana.sh` не удаляют существующие контейнеры
`vm` и `grafana`: при конфликте они завершаются с ошибкой. Осознанная замена
выполняется только с явным флагом `--replace`.

После установки:

- Grafana: `http://${MON_HOST}:${GRAFANA_PORT}/` (admin/`${GRAFANA_ADMIN_PASSWORD:-admin}`).
- Снаружи лаба — через SSH-туннель: `ssh -L ${GRAFANA_PORT}:localhost:${GRAFANA_PORT} ${MON_HOST}`.
- VictoriaMetrics: `http://${MON_HOST}:${VM_PORT}/-/ready`, targets: `/api/v1/targets`.

## Локальный запуск через Compose

Для разработки на Windows стек запускается через Podman, а на Linux тот же файл
можно использовать с Docker. Compose переиспользует dashboards из этого каталога
и поднимает VictoriaMetrics, Grafana и непривилегированный node_exporter в
закрытой сети `chaos-monitoring`. VictoriaMetrics также собирает метрики
локальной YDB с `host.containers.internal:8765` и контейнерного workload с
`workshop-load:9091`. Для health-check порт workload дополнительно привязан к
`127.0.0.1` хоста и не публикуется во внешнюю сеть.

Сначала задайте пароль администратора Grafana. Порты привязаны только к
`127.0.0.1` и не публикуются во внешнюю сеть:

```powershell
# Windows
$env:GRAFANA_ADMIN_PASSWORD = '<local-password>'
podman compose -f grafana/compose.yaml up -d
```

```bash
# Linux
export GRAFANA_ADMIN_PASSWORD='<local-password>'
docker compose -f grafana/compose.yaml up -d
```

После запуска:

- VictoriaMetrics: `http://localhost:8428`;
- Grafana: `http://localhost:3000` (`admin` и заданный пароль).
- scrape targets: `http://localhost:8428/targets`.

В локальном режиме секция Servers показывает доступные из непривилегированного
контейнера метрики Linux-машины Podman/Docker. Это не метрики Windows-хоста.
На полноценном Linux-стенде `02-node-exporter.sh` устанавливает exporter
непосредственно на каждый сервер YDB.

Если volume Grafana уже был инициализирован с другим паролем, смените его явно:

```bash
podman exec grafana grafana cli admin reset-admin-password '<new-local-password>'
```

Для локального compose workload запускается из проекта
`deep-tech-ydb-searches` отдельным compose-файлом в общей сети
`chaos-monitoring`; VictoriaMetrics обращается к `workshop-load:9091`. На
Linux-стенде workload слушает `127.0.0.1:9091`, доступный VictoriaMetrics
благодаря `--network host`.
Боевой сбор внутренних метрик полноценного кластера продолжает использовать
сгенерированный `scrape.yml` и таргеты из `01-victoria.sh`.

Остановить контейнеры, сохранив данные:

```bash
podman compose -f grafana/compose.yaml down
```

---

## Конфигурация (env.sh)

Все переменные — в корневом `env.sh` стенда:

```bash
MON_HOST="chaos-client.chaos-md.ydb.tech"  # где Grafana и VictoriaMetrics
YDB_MON_PORTS="8765,8767,8768"             # порты мониторинга на нодах; при необходимости допишите
YDB_MON_PD_PORT=8765                       # порт мониторинга узла хранения (pdisks/vdisks)
NODE_EXPORTER_PORT=9100
NODE_EXPORTER_VERSION="1.8.2"
GRAFANA_DOCKER_IMAGE="grafana/grafana:11.3.0"
VICTORIA_DOCKER_IMAGE="victoriametrics/victoria-metrics:v1.106.1"
VM_DATA_DIR="/var/lib/victoriametrics"
VM_CONFIG_DIR="/etc/victoriametrics"
VM_TARGETS_DIR="/etc/prometheus"
VM_PORT=8428
VM_RETENTION="30d"
VM_LATENCY_OFFSET="0s"
WORKLOAD_METRICS_TARGET="127.0.0.1:9091"
OBSERVER_METRICS_TARGET="127.0.0.1:9092"
GRAFANA_DATA_DIR="/var/lib/grafana"
GRAFANA_PORT=3000
```

`VM_CONFIG_DIR` хранит основной scrape-конфиг на хосте, а
`VM_TARGETS_DIR` — сгенерированные target-файлы. Старое имя
`VM_FILE_SD_DIR` также поддерживается. Если на хосте уже работает
другой Prometheus/VictoriaMetrics, задайте отдельные каталоги. В контейнере
target-файлы по-прежнему монтируются в `/etc/prometheus`, поэтому менять
`scrape.yml` не требуется.

`OBSERVER_METRICS_TARGET` необязателен для обычных chaos-тестов. В поисковом
воркшопе это независимый процесс, который читает `.sys/partition_stats` и
публикует детализацию таблицы и индексов. Он не управляется lifecycle workload:
остановка или смена профиля нагрузки не должна обрывать эти серии.

Секреты (`GRAFANA_TOKEN` для аннотаций, `GRAFANA_ADMIN_PASSWORD` для UI) — в `env.local.sh` корня (gitignored).

### Почему workload работает через scrape

Workload может отправлять метрики push-запросами, но основной режим для
chaos-тестов — scrape endpoint самого процесса. Это различие важно именно для
наблюдения за отказами:

- VictoriaMetrics явно показывает workload как `UP` или `DOWN`;
- после завершения процесса серии получают штатный признак устаревания и линия
  на графике заканчивается;
- отсутствие процесса нельзя перепутать с неизменившимся последним значением;
- workload, YDB и серверы наблюдаются одним механизмом.

Push остаётся запасным режимом для сетевых схем, где VictoriaMetrics не может
обратиться к процессу нагрузки. Одновременно включать scrape и push для одного
процесса не следует: это создаст две серии с одинаковым смыслом.

Dashboard использует `nowDelay: 2s`, то есть не показывает последние два
незавершённых интервала scrape. Без этой задержки PromQL range query удерживает
последнее значение gauge до правой границы графика, и у живых workload-метрик
появляется короткий плоский хвост, которого нет среди реально сохранённых
samples. Задержка не меняет сами метрики и не мешает штатно отображать
остановку workload как разрыв серии.

В основном dashboard есть отдельная секция `Search index partitions`: число
партиций, объём и CPU основной таблицы и служебных таблиц поисковых индексов.
Эти данные публикует независимый search observer из `.sys/partition_stats`;
его можно держать запущенным между профилями нагрузки. Общие метрики YDB
по-прежнему приходят напрямую с monitoring endpoint базы.

Секция `Actor pools by dynamic node` показывает загрузку `User` и `IC`
пулов каждого dynamic-узла. Делитель берётся из
`utils_CurrentThreadCount`, поэтому панели корректно отражают изменение
числа потоков actor-system auto-config.

В секции workload панель `RPS` сопоставляет фактический и заданный
поток, а `Retries / Dropped` показывает повторы и клиентские дропы.
Этих трёх рядов достаточно, чтобы отличить рост throughput от простого
повышения целевой нагрузки.

Компактный dashboard `deep-tech-search-demo.json` оставляет только метрики
воркшопа. На RPS-графике пунктиром показана заданная нагрузка, отдельная панель
показывает реальные ошибки YDB и ретраи SDK в секунду, а нижние панели — объём
данных и суммарное число партиций основной таблицы и служебных таблиц поисковых
индексов. Пропуски из-за заполнения клиентской очереди остаются диагностической
метрикой workload и не смешиваются с ошибками базы.

Структурный smoke без внешних зависимостей:

```bash
python3 grafana/tests/dashboard-smoke.py
```

---

## Аннотации chaos-окон в Grafana

`lib/grafana.sh` создаёт интервальные и точечные аннотации с базовым тегом
`chaos`. Дополнительный тег `event:<категория>` позволяет дашборду различать
отказы, нагрузку и управляющие действия, не меняя общий механизм аннотаций.

| Событие | Теги | Цвет |
|---|---|---|
| Отказ: `CHAOS_START` → `CHAOS_END/CANCEL` | `chaos`, `event:failure`, `<имя-теста>` | красный регион |
| Работа профиля нагрузки | `chaos`, `event:workload`, `workload-<тип>` | спокойный регион |
| Изменение конфигурации или ёмкости | `chaos`, `event:control`, `<действие>` | точечная отметка |
| Те же при `--dry-run` | `chaos-dry`, `event:<категория>`, `<имя>` | настраивается дашбордом |

Чтобы аннотации появились на ваших дашбордах:

1. Создать service account и токен (Editor) в Grafana, прописать в `env.local.sh`:
   ```bash
   GRAFANA_URL="http://${MON_HOST}:${GRAFANA_PORT}"
   GRAFANA_TOKEN="glsa_xxxxxxxx"
   ```
2. Для общей ленты добавить annotation query по тегу `chaos`. Если события
   нужно различать цветом, создать отдельные запросы по парам тегов:
   `chaos + event:failure`, `chaos + event:workload` и
   `chaos + event:control`.

---

## Hot-update дашборда (без перезапуска контейнера)

`./grafana/deploy-dashboard.sh` — апдейт через API:

```bash
./grafana/deploy-dashboard.sh
```

Скрипт спрашивает имя (последнее запоминается в `grafana/.chaos-grafana-last`). Source — `grafana/dashboards/chaos/chaos-tests.json`. Удобно держать рабочий и тестовый дашборды (разные имена).

Другой JSON можно обновить тем же API без перезапуска Grafana:

```bash
GRAFANA_DASH_FILE="grafana/dashboards/chaos/deep-tech-search-demo.json" \
GRAFANA_DASH_NAME="Deep Tech: YDB Search Demo" \
./grafana/deploy-dashboard.sh
```

---

## Структура каталога

```
grafana/
├── 01-victoria.sh                — install VictoriaMetrics
├── 02-node-exporter.sh           — install node_exporter на CLUSTER_HOSTS
├── 03-grafana.sh                 — install Grafana
├── 04-dashboards-provision.sh    — рендер provisioning + restart
├── deploy-dashboard.sh           — API-апдейт дашборда (hot)
├── annotate.sh                   — создать аннотацию
├── edit-annotation.sh            — TUI редактор аннотаций
├── edit_annotation.py            — Python-реализация TUI
├── requirements-editor.txt       — зависимости edit_annotation.py
├── dashboards/
│   └── chaos-tests.json          — основной дашборд хаос-тестов
└── provisioning/
    ├── datasources/
    │   ├── victoriametrics.yml.tmpl   — шаблон (рендерится 04-скриптом)
    │   └── victoriametrics.yml        — сгенерированный (.gitignore)
    └── dashboards/
        └── dashboards.yml         — file-provider для /var/lib/grafana/dashboards
```

---
