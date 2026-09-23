//  Capture — реализация `AudioCapturePort` (C-004 v5, MEE-77) по перечню MEE-310 и плану
//  MEE-315. Задача — MEE-317.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Каталог принадлежит владельцу модуля: файлы здесь изменяет только он (П1).
//  Всё, что пересекает границу модуля, описано контрактом архитектора и меняется
//  только через interface-request (П2, П6). Границы и запреты — docs/module-map.md.
//
//  Карта файлов:
//  * `AudioCaptureImpl*.swift` — единственный публичный тип (инвариант 25) и его состояние:
//    фаза сеанса, гонка права (`start`), пересборка aggregate, буферы, события шва.
//  * `CaptureSeam*.swift`, `CapturePromptRace.swift`, `CapturePollDriver.swift` — шов модуля
//    (план MEE-315 §«Шов»): протоколы, которые тест подставляет фейком, а прод — `CoreAudioGateway`.
//  * `CoreAudio*.swift` — реализация шва поверх Core Audio HAL, по образцу спайка MEE-8
//    (`spikes/capture-cli`).
//  * `TrackFile.swift` — трек на диске (CAF), точка входа записи, package-видимая для
//    `CaptureManualHarness` (писатель К27(б), MEE-316).
//  * `CaptureManifest.swift`, `CaptureRecovery.swift`, `ScaleError.swift` — C-002/§«Оценка
//    ошибки шкалы».
