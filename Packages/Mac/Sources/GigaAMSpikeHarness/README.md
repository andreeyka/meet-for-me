# GigaAMSpikeHarness

Спайк R12 (`docs/architecture.md`): реальная скорость (RTF), пиковая память и время загрузки
GigaAM v3 `e2e_ctc` на Apple Silicon через sherpa-onnx (C API, ONNX Runtime, CPU — решение
Q10 `architecture.md`). Владелец задачи — Архитектор (MEE-426). Код спайка, не модуль:
`docs/module-map.md` — «Спайки не принадлежат модулям, результат — измерения и выводы»; живёт
в `Packages/Mac`, а не в `spikes/`, только потому что `spikes/` не собирает CI, а готовность
MEE-426 требует зелёной сборки на `macos-14`.

Ни модель, ни тестовая запись в репозиторий не входят — источник модели и её лицензия названы
запиской MEE-426 (комментарий в issue), `scripts/download-model.sh` только печатает URL/размер
и ничего не скачивает без `--yes`.

## Сборка

```sh
Packages/Mac/Sources/GigaAMSpikeHarness/scripts/build.sh
```

`swift build -c release --product GigaAMSpikeHarness`. Без `.app`-обёртки и без подписи —
спайку не нужна ни одна TCC-защищённая возможность (не микрофон, не календарь), в отличие от
`CaptureManualHarness`/`CalendarEventKitManualHarness`.

## Модель

```sh
Packages/Mac/Sources/GigaAMSpikeHarness/scripts/download-model.sh          # только печать
Packages/Mac/Sources/GigaAMSpikeHarness/scripts/download-model.sh --yes    # печать + загрузка
```

Печатает источник (кандидат А записки MEE-426 — sherpa-onnx-экспорт), точный размер и sha256
которого эта сессия не смогла подтвердить (`huggingface.co` недоступен из песочницы, где
писалась записка) — **сверьте со страницей Hugging Face лично, прежде чем подтверждать
`--yes`**. Формат — `nemo_ctc`: один файл энкодера CTC (ONNX) плюс файл словаря токенов.

## Запуск

```sh
Packages/Mac/Sources/GigaAMSpikeHarness/scripts/run.sh \
  --model models/gigaam-v3-e2e-ctc/gigaam_v3_e2e_ctc.onnx \
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

Число потоков ONNX Runtime — `--threads N` (по умолчанию 4).

## Что дальше

Измерения — комментарием в [MEE-426](https://linear.app/easypto/issue/MEE-426), не файлом в
этом каталоге: план часового прогона на базовом M2/M5, тепловое состояние и сравнение
таймстампов с forced alignment — за РП (снимает R12/R14 полностью; см. записку и критерии
успеха там же). Код спайка в модуль `gigaam` (`Packages/Core/Sources/GigaAM/`, владелец
DEV-2) не переезжает без отдельной задачи с контрактом (`docs/module-map.md`).
