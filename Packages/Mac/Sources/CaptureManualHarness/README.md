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

`swift build`/`swift test` печатают предупреждение "unhandled files" на `Bundle/` и `scripts/` —
SwiftPM сканирует весь `Sources/CaptureManualHarness/` и не узнаёт `.plist`/`.sh` без объявления
`exclude:`/`resources:` в `Package.swift`. Принятое ограничение, не дефект: `Package.swift` вне
зоны этой задачи (владелец — архитектор), а вынос `Bundle/`/`scripts/` за пределы
`Sources/CaptureManualHarness/` увёл бы их из зоны тоже (эта задача — три названных каталога плюс
`docs/module-map.md`, ничего снаружи). Предупреждение не мешает ни сборке, ни `swift test`, ни CI
(`-Werror` на предупреждения SwiftPM здесь не включён).

## М1 — право на системный звук (~15 мин)

`--group-app-key`/`--group-pid` обязаны называть РЕАЛЬНО звучащий процесс: `appKey` — это
bundle id как есть, БЕЗ префикса `bundle:` (`ProcessGroup.appKey`, `DomainCore/
ProcessMonitorPort.swift` — «непустая строка», без какого-либо формата-обёртки); фиктивный pid
вроде `1` не транслируется в HAL-объект (`kAudioHardwarePropertyTranslatePIDToProcessObject`),
и `requestSystemAudioTap` вернёт `systemUnavailable` ДО системного промпта — сценарий М1
вообще не начнётся (см. `CoreAudioGateway.requestSystemAudioTap`: пустой список HAL-объектов
из `group.pids` — сразу `systemUnavailable`, без обращения к TCC).

1. Открыть приложение, которое прямо сейчас реально выводит звук САМО, а не через дочерний
   helper-процесс — например, Music.app с играющим треком. НЕ вкладку браузера: у Chrome/Safari
   звук выводит отдельный процесс-помощник (GPU/renderer helper) со своим PID, а не главный
   процесс браузера — pid главного процесса не транслируется в HAL-объект с активным звуком, и
   промпт не появится по той же причине, что и с `--group-pid 1`.
2. Найти его PID и bundle id. `pgrep` без `-d` печатает один PID на строку — если совпадений
   несколько, все они попадают в `--group-pid` через `$(...)` одним аргументом с переводами
   строк, харнесс разбирает и запятую, и пробельные разделители:

   ```sh
   pgrep -x Music                          # PID (может быть несколько строк)
   osascript -e 'id of app "Music"'        # bundle id, например com.apple.Music
   ```

3. `tccutil reset All com.andreeyka.meetforme.spike.capture.harness`
4. Запустить харнесс (через `open`, чтобы TCC отнёс промпт к bundle id харнесса, а не к терминалу)
   с НАСТОЯЩИМИ значениями из шага 2, `--input none` (М1 — только про системный звук):

   ```sh
   Packages/Mac/Sources/CaptureManualHarness/scripts/run.sh \
     start --directory /tmp/mee-317-m1 --seconds 30 --input none \
     --group-app-key com.apple.Music --group-pid "$(pgrep -x Music)"
   ```

   (`com.apple.Music`/`Music` — пример; подставить bundle id и имя процесса реально
   выбранного в шаге 1 приложения.)

5. Дождаться системного промпта о доступе к звуку других приложений; нажать **«Запретить»**.
6. Сверить вывод:
   - дословно `start: throw systemAudioDenied` (не `systemUnavailable` — это отличило бы отказ
     права от любого другого системного сбоя);
   - в потоке событий строка, СОДЕРЖАЩАЯ `permissionObserved`, `systemAudioRecording` и `denied`
     — не обязательно дословно `event: permissionObserved(kind: systemAudioRecording,
     status: denied)`: `PermissionKind`/`PermissionStatus` — типы `DomainCore`, вложенные в
     `CaptureEvent` того же модуля не помечены `CustomStringConvertible`, и Swift печатает такие
     вложенные значения полным именем (`DomainCore.PermissionKind.systemAudioRecording`), не
     голым именем случая — точная строка не прогнана здесь ни разу (нет живого Mac), «дословно»
     было бы утверждением без прогона.

## М2 — микрофонный промпт (~15–20 мин, включает ожидание)

БЕЗ `--group-app-key`/`--group-pid` в обоих запусках ниже: с группой (даже пустой/фиктивной)
`start()` сначала гонит `acquireTap` (`AudioCaptureImplStart.performStart` — tap запрашивается
ДО микрофона) и уходит в `systemUnavailable`/`systemAudioDenied` раньше, чем вообще дойдёт до
`acquireMicrophone`, — промпт микрофона в этом случае не проверить вовсе. `group: nil` эту
попытку пропускает целиком (`acquireTap`: `guard let group else { return nil }`).

Каждый шаг ниже начинается со СВОЕГО `tccutil reset` — решённое право (тем же bundle id) не
переспрашивает при следующем запуске (план MEE-315 §5, п. 5: каждый ручной шаг стартует со
свежего права).

1. `tccutil reset All com.andreeyka.meetforme.spike.capture.harness`
2. Первый запуск — нажать **«Запретить»** на промпте `AVCaptureDevice.requestAccess`:

   ```sh
   Packages/Mac/Sources/CaptureManualHarness/scripts/run.sh \
     start --directory /tmp/mee-317-m2a --seconds 30 --input default
   ```

   Сверить дословно: `start: throw microphoneDenied` (события `permissionObserved` для
   микрофона контракт не заводит — инвариант 16, в потоке событий ничего искать не нужно).
3. `tccutil reset All com.andreeyka.meetforme.spike.capture.harness`
4. Второй запуск — на промпте не отвечать **≥45 секунд**:

   ```sh
   Packages/Mac/Sources/CaptureManualHarness/scripts/run.sh \
     start --directory /tmp/mee-317-m2b --seconds 60 --input default
   ```

   Сверить дословно: `start: throw microphonePromptTimedOut(waitedSeconds: 45)`.

Оба сценария выводят исход `start(_:)` и построчный поток `events()` — записывать дословно из
stdout харнесса (лог также остаётся в `Packages/Mac/.build/logs/<время>.out`).

## Писатель (К27б)

Отдельный подрежим, не для ручного запуска — им управляет `HarnessWriterKillTests` (способ Д):
`CaptureManualHarness write --directory DIR --channel mic|system [опции]` открывает трек и
`manifest.json` тем же путём, что и реализация (`TrackFile`/`ManifestWriter`, `package`-видимые
внутри `Capture`), дописывает синтетический PCM порциями и не завершается штатно — тест убивает
процесс `SIGKILL` в контролируемый момент и проверяет `recover(directory:)` отдельно.
