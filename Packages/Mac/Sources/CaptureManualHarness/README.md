# CaptureManualHarness

Носитель ручных критериев М1/М2 и писатель К27(б) — план проверки MEE-315, §5 и §6.
Каталог принадлежит владельцу модуля `capture` (DEV-1) — правит только он.

Bundle id харнесса: **`com.andreeyka.meetforme.spike.capture.harness`** — отдельный и от
основного приложения, и от `spikes/capture-cli` (`com.andreeyka.meetforme.spike.capture`),
как называет план MEE-315 §5. Права TCC (Privacy & Security → Microphone / Screen & System
Audio Recording) выдаются именно на этот bundle id.

## Сборка

```sh
Packages/Mac/Sources/CaptureManualHarness/scripts/build.sh
```

Собирает `CaptureManualHarness` (`swift build -c release --product CaptureManualHarness`),
оборачивает в `.build/CaptureManualHarness.app` и подписывает сертификатом Apple Development
(`IDENTITY=... scripts/build.sh` — переопределить при другом сертификате). Пересборка тем же
сертификатом сохраняет уже выданные права TCC; ad-hoc подпись — нет.

## М1 — право на системный звук (~15 мин)

1. `tccutil reset All com.andreeyka.meetforme.spike.capture.harness`
2. Запустить харнесс (через `open`, чтобы TCC отнёс промпт к bundle id харнесса, а не к терминалу):

   ```sh
   Packages/Mac/Sources/CaptureManualHarness/scripts/run.sh \
     start --directory /tmp/mee-317-m1 --seconds 30 \
     --group-app-key bundle:example --group-pid 1
   ```

3. Дождаться системного промпта о доступе к звуку других приложений; нажать **«Запретить»**.
4. Сверить вывод: строка `start: throw systemAudioDenied` (не `systemUnavailable`), и
   `event: permissionObserved(kind: systemAudioRecording, status: denied)` в потоке событий.

## М2 — микрофонный промпт (~15–20 мин, включает ожидание)

1. `tccutil reset All com.andreeyka.meetforme.spike.capture.harness` (если ещё не сброшено в
   этом же походе — можно не повторять после М1).
2. Первый запуск — нажать «Запретить» на промпте `AVCaptureDevice.requestAccess`:

   ```sh
   Packages/Mac/Sources/CaptureManualHarness/scripts/run.sh \
     start --directory /tmp/mee-317-m2a --seconds 30 --input default --group-app-key bundle:example --group-pid 1
   ```

   Сверить: `start: throw microphoneDenied`.
3. Второй запуск — на промпте не отвечать **≥45 секунд**:

   ```sh
   Packages/Mac/Sources/CaptureManualHarness/scripts/run.sh \
     start --directory /tmp/mee-317-m2b --seconds 60 --input default --group-app-key bundle:example --group-pid 1
   ```

   Сверить: `start: throw microphonePromptTimedOut(waitedSeconds: 45)`.

Оба сценария выводят исход `start(_:)` и построчный поток `events()` — записывать дословно из
stdout харнесса (лог также остаётся в `Packages/Mac/.build/logs/<время>.out`).

## Писатель (К27б)

Отдельный подрежим, не для ручного запуска — им управляет `HarnessWriterKillTests` (способ Д):
`CaptureManualHarness write --directory DIR --channel mic|system [опции]` открывает трек и
`manifest.json` тем же путём, что и реализация (`TrackFile`/`ManifestWriter`, `package`-видимые
внутри `Capture`), дописывает синтетический PCM порциями и не завершается штатно — тест убивает
процесс `SIGKILL` в контролируемый момент и проверяет `recover(directory:)` отдельно.
