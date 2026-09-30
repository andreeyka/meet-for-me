# GigaAMXPCHarness — стенд Z6 (MEE-504)

Хост-клиент для прогона настоящего `TranscriptionEngine.xpc` на Mac: `EngineXPCClient` →
`NSXPCConnection(serviceName:)` → процесс сервиса (hardened runtime, подпись ad-hoc) →
`GigaAMEngine` + sherpa-onnx. Меряет RTF, пик RSS процесса сервиса, отзывчивость `ping` во
время распознавания, отмену и отказ «нет модели». Режим `download` — проверка Z7 п. 6 (MEE-452):
`ModelCatalogManager.download` из встроенного каталога по сети, пауза на ~50 % и докачка.

CI стенд не собирает (spikes/README.md). Тестовые аудио и модель в репозиторий не кладутся.

## Сборка

```sh
spikes/GigaAMXPCHarness/scripts/build.sh
```

Скрипт генерирует проект (`xcodegen`), собирает `MeetForMe` в Release с подписью ad-hoc
(`DerivedData/` в корне репозитория — под `/tmp` SwiftPM не распаковывает XCFramework
onnxruntime-libs), собирает стенд и кладёт `TranscriptionEngine.xpc` в
`.build/GigaAMXPCHarness.app/Contents/XPCServices/`, подписывает бандл ad-hoc с hardened runtime.

## Запуск

```sh
APP=spikes/GigaAMXPCHarness/.build/GigaAMXPCHarness.app/Contents/MacOS/GigaAMXPCHarness
# каталог модели: model.int8.onnx, tokens.txt и обязательный .manifest.json (пишет model-manager
# или `download`); без него, с чужим schemaVersion или с манифестом другой модели — modelMissing
$APP transcribe --model <каталог> --system sys613.caf --mic mic17.caf --out r613.json
$APP transcribe --model <каталог> --system sys3607.caf --mic mic17.caf --cancel-at 0.5 --out cancel.json
$APP transcribe --model <пустой каталог> --system sys613.caf --out missing.json
# download — без .app: SwiftPM-ресурс каталога ищется рядом с исполняемым файлом
spikes/GigaAMXPCHarness/.build/release/GigaAMXPCHarness download --root <временный каталог> --out z7.json
```

`--system` — `pcm-caf` 48 кГц стерео, `--mic` — моно (как пишет захват). Синтетика: пять
предложений `say -v Milena`, повтор с паузой 0,5 с, склейка и `afconvert -f caff -d LEF32@48000`.

## Лог швов

Сервис пишет каждое место разреза в unified log (`notice`, подсистема
`com.andreeyka.meetforme.TranscriptionEngine`, категория `seams`):

```sh
/usr/bin/log show --last 2h --info \
  --predicate 'subsystem == "com.andreeyka.meetforme.TranscriptionEngine" AND category == "seams"'
```
