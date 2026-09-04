# Параметры сценариев отказоустойчивости

Скопируйте `env.example.sh` в игнорируемый Git файл `env.local.sh` и укажите
имена systemd-юнитов и raw-диска конкретного стенда:

```bash
cp reliability/env.example.sh reliability/env.local.sh
editor reliability/env.local.sh
```

Файл автоматически читают сценарии:

- `03-disk-fail.sh` — временная смена GPT partlabel raw-диска;
- `09-proc-kill.sh` — SIGKILL процессов YDB;
- `12-server-stop.sh` — остановка и последующий старт YDB-сервисов.

Перед первым дисковым тестом обязательно выполните read-only проверку:

```bash
./03-disk-fail.sh -C ydb-s1 -d vdb
```

Сценарий дополнительно проверит устройство непосредственно перед изменением и
не станет работать со смонтированным разделом или неожиданной partlabel.
