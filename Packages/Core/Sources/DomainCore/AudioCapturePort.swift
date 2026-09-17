//  AudioCapturePort — контракт C-004 (MEE-77), раздел «Определение», §§1—4
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-289, прецедент формы — MEE-86). Реализацию порта пишет
//  модуль `capture` (Packages/Mac/Sources/Capture/); фейка `AudioCapturePort` в дереве нет —
//  он предмет MEE-290 и ляжет в Packages/Core/Sources/DomainTestKit/.
//
//  Состав взят из раздела «Определение» этого контракта целиком, а не из перечисления
//  §6 плана MEE-288: план назвал четыре типа (CaptureRequest, CaptureEvent, CaptureStarted,
//  CaptureError), а «Определение» объявляет одиннадцать, и без остальных семи ни один
//  из четырёх не компилируется. Сверено с разрешённым списком инварианта 25 C-004
//  (34 позиции): собственных имён контракта там ровно эти одиннадцать.
//
//  Порядок типов и порядок полей внутри типа — дословно по §§1—4 контракта
//  (порядок значим: правило обхода C-001 §0.2 п. 9).

import Foundation

// MARK: - §1. Константы

public enum AudioCaptureLimits {
    /// Предел ожидания ответа пользователя на промпт права системного звука.
    public static let systemAudioPromptWaitSeconds: Int = 45

    /// Предел ожидания микрофонного канала при старте.
    public static let microphonePromptWaitSeconds: Int = 45

    /// Порог, после которого незавершённый старт считается ожиданием пользователя (эвристика).
    public static let promptPendingHintMs: Int = 1000

    /// Нижний предел оценки ошибки шкалы для разрыва с неустановленной причиной.
    public static let scaleErrorFloorMs: Int = 150

    /// Верхний предел потери хвоста при аварийном завершении процесса.
    /// Он же — предельный интервал сброса буферов на диск (инвариант 26).
    public static let truncatedTailBudgetMs: Int = 250

    /// Не реже этого порт перечитывает фактический состав tap.
    public static let capturedProcessesPollSeconds: Int = 10

    /// Задержка против дребезга при смене устройства ввода.
    public static let deviceChangeDebounceMs: Int = 200

    /// Пауза перед попыткой пересоздать инвалидированный tap.
    public static let tapRecreateBackoffMs: Int = 1000
}

// MARK: - §2. Значения на входе

public struct TrackFormat: Codable, Equatable, Sendable {
    public let sampleRate: Int     // Гц, как будет записано на диск
    public let channelCount: Int

    public init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

public enum InputSelection: Codable, Equatable, Sendable {
    case systemDefault        // следовать устройству ввода по умолчанию, включая его смену
    case uid(String)          // конкретное устройство
    case none                 // микрофонный канал не записывается
}

public struct CaptureRequest: Codable, Equatable, Sendable {
    public let recordingId: UUID
    public let meetingId: UUID?
    public let directory: URL           // каталог записи, созданный storage (C-010 §1)
    public let group: ProcessGroup?     // C-009; nil — системный канал не записывается
    public let input: InputSelection
    public let systemFormat: TrackFormat
    public let micFormat: TrackFormat

    public init(
        recordingId: UUID,
        meetingId: UUID?,
        directory: URL,
        group: ProcessGroup?,
        input: InputSelection,
        systemFormat: TrackFormat,
        micFormat: TrackFormat
    ) {
        self.recordingId = recordingId
        self.meetingId = meetingId
        self.directory = directory
        self.group = group
        self.input = input
        self.systemFormat = systemFormat
        self.micFormat = micFormat
    }
}

// MARK: - §3. Значения на выходе

public struct CaptureStarted: Codable, Equatable, Sendable {
    public let recordingId: UUID
    public let startedAt: Date                       // момент позиции 0 опорного трека (C-002)
    public let tracks: [RecordingManifest.Track]     // C-002; ровно то, что объявлено в манифесте
    public let captureGroupKey: String?              // == group?.appKey

    public init(
        recordingId: UUID,
        startedAt: Date,
        tracks: [RecordingManifest.Track],
        captureGroupKey: String?
    ) {
        self.recordingId = recordingId
        self.startedAt = startedAt
        self.tracks = tracks
        self.captureGroupKey = captureGroupKey
    }
}

/// Разрыв временной шкалы в момент, когда он произошёл.
public struct CaptureDiscontinuity: Codable, Equatable, Sendable {
    public let atMs: Int
    public let gapMs: Int
    public let scaleErrorMs: Int
    public let reason: RecordingManifest.DiscontinuityReason   // C-002
    /// Измеренная недостача файла против host time на момент разрыва; nil — измерить не удалось.
    public let fileMinusHostMs: Int?

    public init(
        atMs: Int,
        gapMs: Int,
        scaleErrorMs: Int,
        reason: RecordingManifest.DiscontinuityReason,
        fileMinusHostMs: Int?
    ) {
        self.atMs = atMs
        self.gapMs = gapMs
        self.scaleErrorMs = scaleErrorMs
        self.reason = reason
        self.fileMinusHostMs = fileMinusHostMs
    }
}

/// Фактический состав tap на момент чтения. См. §«Состав захвата».
public struct CapturedProcessSnapshot: Codable, Equatable, Sendable {
    public let atMs: Int
    public let observedAt: Date
    public let requestedAppKey: String?                        // по чему просили (C-009)
    public let resolvedBundleIds: [String]                     // что HAL записал в описание tap
    public let processes: [RecordingManifest.CapturedProcess]  // C-002
    public let containsUnrequested: Bool                       // см. инвариант 13

    public init(
        atMs: Int,
        observedAt: Date,
        requestedAppKey: String?,
        resolvedBundleIds: [String],
        processes: [RecordingManifest.CapturedProcess],
        containsUnrequested: Bool
    ) {
        self.atMs = atMs
        self.observedAt = observedAt
        self.requestedAppKey = requestedAppKey
        self.resolvedBundleIds = resolvedBundleIds
        self.processes = processes
        self.containsUnrequested = containsUnrequested
    }
}

public struct CaptureLevels: Equatable, Sendable {
    public let mic: Float?      // 0...1; nil — канала нет
    public let system: Float?   // 0...1; nil — канала нет

    public init(mic: Float?, system: Float?) {
        self.mic = mic
        self.system = system
    }
}

public enum CaptureEvent: Equatable, Sendable {
    case started(CaptureStarted)
    case inputDeviceChanged(RecordingManifest.InputDeviceSpan)    // C-002; маркер уже поставлен
    case inputFormatChanged(from: TrackFormat, to: TrackFormat)   // источник сменил формат
    case discontinuity(CaptureDiscontinuity)
    case capturedProcessesChanged(CapturedProcessSnapshot)
    case levels(CaptureLevels)
    case systemSilent(sinceMs: Int)                               // в системном треке тишина
    case promptPending(kind: PermissionKind)                      // C-007; эвристика
    case permissionObserved(kind: PermissionKind, status: PermissionStatus)  // C-007
    case paused(atMs: Int)
    case resumed(atMs: Int)
    case stopped(RecordingManifest)                               // итоговый манифест
    case failed(CaptureError)
}

public enum CaptureError: Error, Codable, Equatable, Sendable {
    case alreadyRunning
    case notRunning
    case nothingToCapture                        // group == nil и input == .none
    case systemAudioDenied                       // tap не создан: право не выдано
    case systemAudioPromptTimedOut(waitedSeconds: Int)
    case microphoneDenied
    case microphonePromptTimedOut(waitedSeconds: Int)   // микрофонный канал не открылся за предел
    case inputDeviceUnavailable(uid: String)
    case directoryUnusable(message: String)
    case systemUnavailable(message: String)      // отказ Core Audio, не связанный с правом
    case recoveryFailed(directoryName: String, message: String)
}

// MARK: - §4. Протокол

public protocol AudioCapturePort: Sendable {

    /// Начать запись. Возвращается, когда оба запрошенных канала открыты и треки объявлены.
    func start(_ request: CaptureRequest) async throws -> CaptureStarted

    /// Остановить запись и финализировать манифест. Возвращает манифест в том виде, в каком он лёг на диск.
    func stop() async throws -> RecordingManifest

    func pause() async throws
    func resume() async throws

    /// Сменить устройство ввода на ходу; пересобирается только aggregate device (инвариант 5).
    func setInput(_ selection: InputSelection) async throws

    func events() -> AsyncStream<CaptureEvent>

    /// Восстановить оборванную запись по её каталогу. См. §«Восстановление оборванной записи».
    func recover(directory: URL) async throws -> RecordingManifest
}
