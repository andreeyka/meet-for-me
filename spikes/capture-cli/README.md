# capture-cli — спайк MEE-8

Swift-CLI для замеров рисков R1, R2, R6, R9 и допущения A2 (`docs/architecture.md`, §10.2). Код одноразовый:
в модули продукта не переезжает, CI его не собирает. Результат спайка — отчёт комментарием в MEE-8.

Что умеет: перечислить процессы-аудиоклиенты HAL; поставить process tap на процесс или группу; собрать aggregate
device «tap + микрофон по умолчанию» с одним IO-callback; писать каналы в раздельные CAF с `data`-чанком неизвестной
длины; вести `manifest.json` по C-002 v2 (MEE-3); пересобирать aggregate device при смене устройства или формата
микрофона с сохранением шкалы (разрыв заполняется тишиной, маркеры `discontinuity`/`deviceChanged`); логировать
события HAL, сон/пробуждение, завершение тапнутого процесса; анализировать записи.

## Сборка и подпись

```bash
spikes/capture-cli/scripts/build.sh
```

Собирает `.build/CaptureCLI.app` (bundle id `com.andreeyka.meetforme.spike.capture`) и подписывает сертификатом
`Apple Development: andrey@skzd.ru (SKX9KNP9CA)`, Team ID `N2V39ZK33Z`, hardened runtime + `com.apple.security.device.audio-input`.
Права TCC привязаны к designated requirement подписи: пересборка тем же сертификатом права сохраняет.
Второй бандл для опытов с отказом: `APP_NAME=CaptureCLIDeny BUNDLE_ID=com.andreeyka.meetforme.spike.capture.deny scripts/build.sh`.

Нужны Swift 6.x и SDK macOS 26 (хватает Command Line Tools).

## Запуск

Команды, которым нужны права (record, vp-hold, tcc), запускаются через LaunchServices:

```bash
spikes/capture-cli/scripts/run.sh record --pid 12345 --seconds 30
```

Запуск бинаря прямо из терминала делает «ответственным процессом» для TCC сам терминал: промпт и запись в
Privacy & Security достанутся ему. `open` делает ответственным CaptureCLI.app. Анализ и плеер права не требуют:
`spikes/capture-cli/.build/release/capture-cli <команда>`.

Полный список команд и флагов — `capture-cli help`. Главные:

| Команда | Зачем |
|---|---|
| `processes [--watch S]` | процессы HAL: pid, ppid, responsible pid, bundle id, `IsRunningOutput/Input` |
| `record ...` | запись; источник: `--pid`, `--bundle-prefix`, `--responsible-pid`, `--bundle-ids` (macOS 26) |
| `play [--band high] [--file F --schedule 5,85]` | опорные чирпы или речь из отдельного процесса на устройство по UID |
| `verify DIR [--killed-at-ms MS]` | что читается на диске после крэша, сколько потеряно, валиден ли манифест |
| `levels DIR` / `channels FILE` | уровни по файлам и по каналам |
| `sync DIR [--band high]` | смещение mic−system по чирпам, уход за время записи, скачки на разрывах |
| `r6 RAW_DIR VP_DIR` | эхо и окраска: сырой микрофон против voice processing |

## Сценарии

| Скрипт | Риск | Человек нужен |
|---|---|---|
| `scripts/r1-probe.sh NAME --pid P` | R1: tap на группу + tap «всё остальное», уровни | идёт звонок в браузере |
| `scripts/webkit-audio-probe.swift` | R1: звук другого WebKit-приложения в tap на WebKit.GPU | нет |
| `scripts/r2-hour.sh` | R2: длинная запись, неслышимые чирпы 17,5–20,5 кГц | для смены устройства |
| `MODE=raw\|vp scripts/r6-echo.sh speech.aiff` | R6: эхо и окраска | читает текст вслух |
| `DUCK=default\|min scripts/r6-vp-side-effects.sh speech.aiff` | R6: ducking и смена формата микрофона при VP в чужом процессе | нет |
| `WRITER=raw\|apple FLUSH_MS=200 scripts/r9-kill.sh` | R9: `kill -9` посреди записи | нет |
| `MODE=pid scripts/tap-process-exit.sh` | завершение и перезапуск тапнутого процесса | нет |

`scripts/events-summary.py DIR/events.log` — сводка событий записи.

## Где записи

`~/Library/Application Support/com.andreeyka.meetforme.spike.capture/recordings/<RECORDING-UUID>/`:

- `audio-mic.caf`, `audio-system.caf` — треки манифеста, PCM Float32, 48 кГц;
- `diag-*.caf` — диагностические треки вне контракта (`diag-rest` — всё кроме группы, `diag-system-nodrift` — tap без
  drift compensation, `diag-mic-vp` — выход voice processing);
- `manifest.json` — C-002 v2, пишется атомарно при старте, на каждом маркере и при остановке;
- `events.log` — JSON Lines, `fsync` на каждой строке; метка сценария — поле `label` события `start`.

## Упрощения спайка

IO-callback копирует буферы в кольцевой буфер под `os_unfair_lock` (без аллокаций), запись на диск — отдельная очередь
раз в `--flush-ms`. Финализации в AAC нет: манифест остаётся `pcm-caf`, `isFinalized=false`. Копия C-002 и его
кодировщика — в `Manifest.swift`, потому что `DomainCore` пока скелет.
