# Архитектура workload lifecycle

Этот документ описывает универсальную интеграцию генераторов нагрузки с
`chaos-md`. Детали search-стенда находятся в
`deep-tech-ydb-searches/docs/architecture.md` в репозитории практической части.

## Зачем нужен отдельный lifecycle

Во время chaos-прогона нагрузка должна начаться до первого воздействия,
оставаться активной между тестами и гарантированно остановиться при штатном
завершении, ошибке или `Ctrl+C`. При этом каждый генератор имеет собственные
команды, конфигурацию и health-проверку.

`manage.sh` отделяет оркестратор от конкретной реализации через adapters.

```text
chaos-md.sh
    │
    ▼
manage.sh --type <adapter> <command>
    │
    ├─ adapters/search.sh ─► deep-tech-ydb-searches
    └─ adapters/stock.sh  ─► legacy ydb workload stock
```

## Контракт adapter

Поддерживаются команды:

- `info` — показать эффективную конфигурацию без запуска;
- `prepare` — выполнить идемпотентную подготовку или проверку;
- `start` — запустить процесс в фоне и дождаться готовности;
- `status` — проверить PID и health;
- `stop` — завершить процесс с таймаутом;
- `run` — запустить workload в foreground;
- `cleanup` — удалить только явно принадлежащие workload ресурсы.
- `action` — выполнить явное adapter-specific действие вне lifecycle процесса.

Adapter отвечает за построение конкретной команды и health-проверку. Manager
отвечает за PID/state, логи, таймауты и единообразную обработку ошибок.

## Жизненный цикл chaos-прогона

```text
parse options
  → workload prepare
  → workload start + health
  → chaos queue
  → trap: workload stop
```

Если `prepare`, `start` или health завершаются ошибкой, разрушительная очередь не
запускается. `--skip-workload-prepare` допустим только для заранее проверенного
стенда. Dry-run сохраняет проверяемый путь управления, но не выполняет
разрушительные SSH-команды.

## Состояние и логи

- PID и runtime state: `workload/.state/`;
- stdout/stderr: `logs/workload/<type>.log`;
- START/END/CANCEL воздействий: общий `logs/timeline.log`;
- Grafana annotations отправляет `chaos-md`, а не workload. Интервал workload
  содержит имя активного профиля, а `action` создаёт точечную засечку.

State и логи не являются источником продуктовых метрик. Они нужны для
управления процессом и диагностики запуска.

На Linux manager запускает workload в отдельной process group и завершает всю
группу. В Git Bash process-group semantics отличаются, поэтому там manager
останавливает PID оболочки и сразу вызывает `adapter stop`; Compose-контейнер
завершается явно и foreground-процесс выходит следом.

## Метрики

Workload публикует клиентские метрики. VictoriaMetrics, Grafana, YDB scrape и
Node Exporter принадлежат общему monitoring stack `chaos-md`.

Для search workload основной режим — Prometheus scrape: после остановки процесса
серия естественно заканчивается. Push остаётся допустимым fallback для сетевых
схем, где scraper не может обратиться к клиенту, но оба режима нельзя включать
одновременно.

## Независимый запуск

Интеграция не запрещает запуск без chaos:

```bash
bash workload/manage.sh --type search prepare
bash workload/manage.sh --type search run
```

Это основной путь для smoke-теста, диагностики запроса и настройки baseline.

## Добавление нового workload

Новая реализация должна:

1. добавить adapter в `workload/adapters/`;
2. валидировать обязательную конфигурацию до запуска;
3. предоставить устойчивую health-проверку;
4. корректно завершаться по SIGTERM;
5. не поднимать собственную копию общего monitoring stack;
6. не выполнять разрушительный cleanup без явной команды.

Изменение Rust TUI для нового типа не требуется, если lifecycle полностью
выражается этим контрактом. Новый флаг нужен только при появлении поведения,
которого контракт не описывает.
