# GigaAMSpike

Спайк R12 (`docs/architecture.md`): реальная скорость (RTF), пиковая память и время загрузки
GigaAM v3 `e2e_ctc` на Apple Silicon через sherpa-onnx (C API, ONNX Runtime, CPU — решение
Q10 `architecture.md`). Владелец задачи — Архитектор (MEE-426). Код спайка, не модуль:
`docs/module-map.md` — «Спайки не принадлежат модулям, результат — измерения и выводы»;
отдельный SwiftPM-пакет (не таргет `Packages/Mac`), потому что зависимость sherpa-onnx тянет
~168 МиБ бинарников — эта цена не должна ложиться на каждую сборку `Packages/Mac` и на каждый
прогон CI (возврат РП, MEE-426, приёмка #158). CI этот пакет не собирает (`spikes/README.md` —
«CI спайки не собирает», тот же приём, что уже принят для `spikes/capture-cli`); сборка
проверяется вручную (`scripts/build.sh`) перед отчётом измерений.

Ни модель, ни тестовая запись в репозиторий не входят — источник модели и её лицензия названы
запиской MEE-426 (комментарий в issue) и приёмкой РП там же; `scripts/download-model.sh` только
печатает URL/размер и ничего не скачивает без `--yes`. Каталог загрузки по умолчанию —
`models/` рядом с этим README, в `.gitignore`.

## Сборка

```sh
spikes/GigaAMSpike/scripts/build.sh
```

`swift build -c release --product GigaAMSpikeHarness`. Без `.app`-обёртки и без подписи —
спайку не нужна ни одна TCC-защищённая возможность (не микрофон, не календарь), в отличие от
`CaptureManualHarness`/`CalendarEventKitManualHarness` (`Packages/Mac`).

## Модель

```sh
spikes/GigaAMSpike/scripts/download-model.sh          # только печать источника
spikes/GigaAMSpike/scripts/download-model.sh --yes    # печать + загрузка + проверка sha256
```

Источник — `Smirnov75/GigaAM-v3-sherpa-onnx` (MIT, апстрим `salute-developers/GigaAM`), файлы
`gigaam_v3_e2e_ctc_int8.onnx` (319 869 121 Б, sha256 в скрипте) и
`gigaam_v3_e2e_ctc_tokens.txt` (2 006 Б) — размеры и хэш из приёмки РП (MEE-426, комментарий
#158, 07:25 UTC), скрипт сверяет их после загрузки и обрывается на расхождении. Формат —
`nemo_ctc`: один файл энкодера CTC (ONNX) плюс файл словаря токенов.

## Запуск

```sh
spikes/GigaAMSpike/scripts/run.sh \
  --model models/gigaam-v3-e2e-ctc/gigaam_v3_e2e_ctc_int8.onnx \
  --tokens models/gigaam-v3-e2e-ctc/gigaam_v3_e2e_ctc_tokens.txt \
  --wav /path/to/16k-mono.wav
```

WAV обязан быть 16 кГц, моно — стенд отказывает с точным несовпадением на любом другом
формате, а не ресемплирует молча (RTF/точность на ресемплированном звуке — не то же
измерение, что на нативном частотном плане, а R12 требует ясности именно в этом).

Печатает: распознанный текст, RTF (время расшифровки / длительность записи), пиковую
резидентную память процесса (МБ, `mach_task_basic_info.resident_size_max` — тот же способ,
что использует Activity Monitor), время загрузки модели (с, разово при старте — тот же
режим, в котором модель живёт в реальном XPC-движке, не перезагрузка на каждый файл).

Число потоков ONNX Runtime — `--threads N` (по умолчанию 4; нечисловое значение — ошибка,
не молчаливый откат к умолчанию).

## Что дальше

Измерения — комментарием в [MEE-426](https://linear.app/easypto/issue/MEE-426), не файлом в
этом каталоге: план часового прогона на базовом M2/M5, тепловое состояние и сравнение
таймстампов с forced alignment — за РП (снимает R12/R14 полностью; см. записку и критерии
успеха там же). Код спайка в модуль `gigaam` (`Packages/Core/Sources/GigaAM/`, владелец
DEV-2) не переезжает без отдельной задачи с контрактом (`docs/module-map.md`).
