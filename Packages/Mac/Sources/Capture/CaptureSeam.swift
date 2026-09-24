//  CaptureSeam — шов модуля `capture`, план MEE-315 §«Шов» / перечень MEE-310 §«Шов».
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  РАЗВИЛКА (постановка MEE-317: «Устройство шва выбираете вы», образец — Detector,
//  HALProcessSource): один связный протокол `HardwareGateway`, а не набор мелких швов по числу
//  системных вызовов (как у Detector — Ш3/Ш4/Ш6 порознь). Довод: у `capture` состав входов
//  (tap + микрофон) и его пересборка в aggregate device — ОДНО связное состояние с общими
//  правилами (инварианты 4—6: tap переживает пересборку, пересобирается только aggregate,
//  дрейф всегда включён), и разнесение по трём протоколам потребовало бы третьего места,
//  синхронизирующего их согласованность в тесте, — а без него противоречивый фейк (tap
//  пересоздан, а aggregate нет) был бы недостижим в проде, но принимался бы тестом. Один
//  протокол связывает состав входов и правило его сборки в одном месте, как это делает
//  сам контракт (§4 «Протокол»). Цена: протокол шире, чем любой шов Detector по отдельности;
//  разбит на методы по стадиям (получить право → собрать aggregate → слушать события), чтобы
//  каждая проверялась независимо.
//
//  Наблюдаемость шва — по перечню MEE-310 §«Шов» дословно:
//  * задать: исход попытки создания tap/aggregate (успех / отказ права / отказ без права /
//    таймаут по времени — здесь через `PromptDeadline`, без эмуляции самого промпта); поток PCM
//    заданной длины/частоты/каналов на каждый из двух треков отдельно (`HardwareBuffer`); момент
//    и вид смены формата/устройства входа; момент инвалидации tap (`HardwareEvent`); частоту
//    сброса буферов на диск (`TrackFile`, соседний файл); принудительное завершение
//    процесса-писателя сигналом (харнесс, вне этого файла);
//  * наблюдать: число и аргументы попыток создания tap/aggregate по отдельности от прочих
//    вызовов (фейк теста ведёт свой журнал — `CaptureTests/FakeHardwareGateway.swift`);
//    последовательность `CaptureEvent` (это уже даёт сам порт); итоговый `RecordingManifest` по
//    файлу на диске; список файлов каталога записи.
//
//  Ручки, требующие живого TCC и живого звука (подлинность исхода промпта, настоящие числа
//  дрейфа/эха), шов НЕ подставляет — контракт называет их границей шва прямо (§«Шов», абзац
//  «Граница шва названа явно»): это М1/М2 и раздел «Опора на приватный API…».

import DomainCore
import Foundation

/// Опаковый идентификатор открытого tap. Не несёт значений HAL — только корреляцию между
/// вызовами шва; конкретный `AudioObjectID` живёт только внутри `CoreAudioGateway`.
struct TapHandle: Sendable, Equatable {
    let token: UUID
    init(token: UUID = UUID()) { self.token = token }
}

/// Опаковый идентификатор открытого микрофонного входа.
struct MicrophoneHandle: Sendable, Equatable {
    let token: UUID
    let uid: String?
    let name: String?
    let channelCount: Int
    init(token: UUID = UUID(), uid: String?, name: String?, channelCount: Int) {
        self.token = token
        self.uid = uid
        self.name = name
        self.channelCount = channelCount
    }
}

/// Опаковый идентификатор собранного aggregate device.
struct AggregateHandle: Sendable, Equatable {
    let token: UUID
    init(token: UUID = UUID()) { self.token = token }
}

/// Исход попытки получить право системного звука — вход и выход шва одновременно: тест задаёт
/// это значение, реализация его наблюдает как результат `HardwareGateway.requestSystemAudioTap`.
enum TapAttempt: Sendable {
    case created(TapHandle)
    case permissionDenied
    case systemUnavailable(message: String)
}

/// Исход попытки открыть микрофонный вход.
enum MicrophoneAttempt: Sendable {
    case opened(MicrophoneHandle)
    case permissionDenied
    /// `InputSelection.uid(_:)` назвало устройство, которого нет либо оно недоступно — inv.
    /// `CaptureError.inputDeviceUnavailable(uid:)`, отдельно от `systemUnavailable`.
    case deviceUnavailable(uid: String)
    case systemUnavailable(message: String)
}

/// Один блок PCM Float32 interleaved с одного из двух входов, после нормализации к объявленному
/// формату трека (инвариант 7 — нормализацию делает `CaptureComposition`, не шов).
struct HardwareBuffer: Sendable {
    enum Slot: Sendable, Equatable { case mic, system }
    let slot: Slot
    let samples: [Float]
    let frameCount: Int
    let channelCount: Int
    /// Момент буфера по монотонным часам машины, в миллисекундах (не по шкале файла — шкалу
    /// файла считает `TrackFile` по числу записанных кадров). Единица — миллисекунды намеренно:
    /// перевод из `mach_absolute_time` в них делает `CoreAudioGateway` один раз на буфер, а не
    /// каждое место, которое сравнивает интервалы.
    let hostTime: UInt64
}

/// Снимок процесса, попавшего в tap, — то немногое, что шов обязан отдать реализации для
/// `CapturedProcessSnapshot` (инварианты 12—14).
struct CaptureProcessDescriptor: Sendable, Equatable {
    let pid: Int32
    let bundleId: String?
    let executableName: String?
    /// C-009 §4.1, шаг 1: `responsibleBundleId ?? bundleId` — appKey процесса. `nil`, если
    /// источник его не знает; шаг 1 сворачивает к `bundleId`, если так.
    let responsibleBundleId: String?
}

extension CaptureProcessDescriptor {
    /// Для мест, которым `responsibleBundleId` неизвестен (весь `CaptureTests`, кроме самого
    /// поля, не источник HAL) — `nil` сворачивает шаг 1 к обычному `bundleId`. Объявлен в
    /// расширении, а не в теле структуры, намеренно: свой `init` в теле структуры подавил бы
    /// синтезированный четырёхаргументный memberwise-инициализатор целиком, а он нужен
    /// `CoreAudioHAL.describedProcesses` — единственному месту, которое знает реальный
    /// `responsibleBundleId`.
    init(pid: Int32, bundleId: String?, executableName: String?) {
        self.init(pid: pid, bundleId: bundleId, executableName: executableName, responsibleBundleId: nil)
    }
}

/// События, наблюдаемые между собранным aggregate device и реализацией. `atHostTime` — момент
/// события в миллисекундах монотонных часов (тот же смысл, что у `HardwareBuffer.hostTime`);
/// перевод в `atMs` шкалы файла делает `AudioCaptureImpl` по позиции опорного трека.
enum HardwareEvent: Sendable {
    case microphoneChanged(MicrophoneHandle?, atHostTime: UInt64)
    case microphoneFormatChanged(channelCount: Int, atHostTime: UInt64)
    case tapInvalidated(atHostTime: UInt64)
    case aggregateDied(atHostTime: UInt64)
    case processesChanged([CaptureProcessDescriptor], atHostTime: UInt64)
    // Сон/пробуждение НЕ здесь: контракт называет источником `.willSleep`/`.didWake` (C-008) —
    // `PowerPort.events()`, а не шов оборудования. `AudioCaptureImpl` подписан на них напрямую
    // (`subscribeToPowerEvents`), минуя `HardwareGateway` целиком.
}

/// Подписка на события шва; отменяется явно, как и `PowerPort`/`ProcessMonitorPort` этого проекта.
protocol HardwareSubscription: Sendable {
    func cancel()
}

/// Шов модуля `capture`. Реализует `CoreAudioGateway` (система) в проде и
/// `FakeHardwareGateway` (`CaptureTests`) в тестах.
///
/// Асинхронность методов получения права — намеренная: реальный вызов блокируется до ответа
/// TCC (замер спайка MEE-8 — секунды, до 50 минут без промпта), и `async` переносит эту
/// блокировку с потока вызывающего на отдельную задачу без остановки очереди порта.
protocol HardwareGateway: Sendable {
    /// Блокируется до ответа HAL. `group == nil` — попытки не будет: вызывающая сторона
    /// обязана проверить `nothingToCapture` раньше (инвариант 3) и не звать это вовсе.
    func requestSystemAudioTap(for group: ProcessGroup?) async -> TapAttempt

    /// Блокируется до ответа TCC. `selection == .none` не зовётся тем же доводом.
    func requestMicrophone(_ selection: InputSelection) async -> MicrophoneAttempt

    func releaseTap(_ handle: TapHandle)
    func releaseMicrophone(_ handle: MicrophoneHandle)

    /// Собрать aggregate device из уже открытых входов и начать доставку буферов в `onBuffer`.
    /// Второй и последующие вызовы с теми же `tap`/`microphone` — пересборка: они обязаны
    /// переиспользовать переданные хэндлы, а не создавать новые (инварианты 4—6 проверяет тест
    /// счётом вызовов `requestSystemAudioTap` и `buildAggregate` порознь).
    ///
    /// `driftCompensation` — аргумент, а не решение самого шва: порт называет им своё требование
    /// «компенсация дрейфа включена всегда» (инвариант 6, дословно у `CoreAudioGateway`) на
    /// каждом вызове, а фейк теста ведёт журнал этого аргумента отдельно от прочих (К6, план
    /// MEE-315). Какой конкретно саб-элемент aggregate внутри реализации остаётся опорными
    /// часами без собственной компенсации — деталь `AggregateRuntime`, этот аргумент её не несёт
    /// и не заменяет.
    func buildAggregate(
        tap: TapHandle?,
        microphone: MicrophoneHandle?,
        driftCompensation: Bool,
        onBuffer: @escaping @Sendable (HardwareBuffer) -> Void
    ) throws -> AggregateHandle

    func teardownAggregate(_ handle: AggregateHandle)

    /// Текущий состав процессов, допущенных HAL к tap (инвариант 12, состав захвата).
    func capturedProcesses(_ tap: TapHandle) -> [CaptureProcessDescriptor]

    /// Подписка на события смены устройства/формата, инвалидации, сна — живёт с портом, не с
    /// сеансом (инвариант 23: `events()` переживает несколько сеансов).
    func subscribeEvents(_ handler: @escaping @Sendable (HardwareEvent) -> Void) -> HardwareSubscription
}

/// Сколько реализация вправе не отвечать на промпт (инвариант 15) — шов Ч2. Реальная реализация
/// спит по часам машины; фейк управляется тестом и не спит по-настоящему («виртуальное время
/// шва» — план MEE-315, К15/К16).
protocol PromptDeadline: Sendable {
    func wait(seconds: Int) async
}

/// Часы машины для предела ожидания — реализация спит по-настоящему.
struct SystemPromptDeadline: PromptDeadline {
    func wait(seconds: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
    }
}
