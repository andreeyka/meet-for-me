//  FakeAudioCapturePort — реализация `AudioCapturePort` в памяти, C-004 §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Состав управляющей поверхности — §«Фейк для тестов» C-004 дословно: задать исход `start`
//  (успех с заданным `CaptureStarted` либо ЛЮБАЯ `CaptureError`); протолкнуть в `events()`
//  любое событие; задать манифест, который вернёт `stop`, и манифест, который вернёт
//  `recover(directory:)`, включая уже восстановленный; ПОСЧИТАТЬ ВЫЗОВЫ `start`, `stop`,
//  `pause`, `resume`, `setInput`, `recover` С АРГУМЕНТАМИ и отдать их тесту списком.
//
//  ГОТОВЫХ МАНИФЕСТОВ ФЕЙК НЕ ЗАВОДИТ — это запрет самого контракта, и он исполнен здесь
//  дословно: их даёт `DomainTestKit.RecordingManifestFixtures` (C-002), включая «оборванную
//  запись, восстановленную производителем» и «смену устройства посередине». Второй набор тех
//  же значений разошёлся бы с первым молча.
//
//  ИСХОД `recover` МОЖЕТ БЫТЬ ОТКАЗОМ, И ЭТО СВЕРХ ТЕКСТА §«Фейк для тестов», а не вольность.
//  Контракт называет там манифест и не называет отказа; К77 плана MEE-288 требует ветви
//  «`recover` бросил `recoveryFailed`» прямым текстом, а `CaptureError.recoveryFailed`
//  объявлен и не производится больше ничем. Средство, которого требует пункт плана и не
//  называет раздел контракта, — находка, и она названа в отчёте MEE-290, а не решена молча:
//  тексты C-004 этой задачей не правятся (§2 постановки).
//
//  ГРАНИЦА УПРАВЛЕНИЯ НАЗВАНА. Бросать умеют `start`, `stop` и `recover` — ровно те, на чьих
//  отказах стоят пункты плана. `pause`, `resume` и `setInput` не бросают никогда: ни один
//  пункт на их отказе не стоит, а средство, заведённое без адресата, читается как
//  проверяемое и не проверяется ничем.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА: он не следит ни за одним инвариантом C-004 — ни за тем,
//  что `stop` идёт после `start`, ни за монотонностью `atMs`, ни за идемпотентностью
//  `recover` (инвариант 18). Тест вправе позвать `stop` первым и получить заданный манифест:
//  без этого ветку «потребитель пережил негодный порядок» не проверить ничем.
//
//  `@unchecked Sendable` с замком, а не актор: `AudioCapturePort` объявлен `: Sendable`,
//  а `events()` синхронен, и актором протокол не покрыть.

import Foundation
import DomainCore

/// Один вызов захвата с его аргументами, в том виде, в каком его получил фейк.
public enum CaptureCall: Equatable, Sendable {
    case start(CaptureRequest)
    case stop
    case pause
    case resume
    case setInput(InputSelection)
    case recover(directory: URL)
}

/// Фейк порта захвата звука. Всё поведение задаёт тест.
public final class FakeAudioCapturePort: AudioCapturePort, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "AudioCapturePort"

    private let lock = NSLock()
    private let log: PortCallLog

    private var startResult: CaptureStarted?
    private var startFailure: CaptureError?
    private var stopManifest: RecordingManifest?
    private var stopFailure: CaptureError?
    private var recoverManifest: RecordingManifest?
    private var recoverFailure: CaptureError?
    private var calls: [CaptureCall] = []
    private var continuations: [AsyncStream<CaptureEvent>.Continuation] = []

    /// - Parameter log: общий журнал вызовов (условие `Н`). Не дали — фейк заводит свой.
    public init(log: PortCallLog = PortCallLog()) {
        self.log = log
    }

    /// Журнал, в который пишет этот фейк. Тот же объект, что передали в инициализатор.
    public var callLog: PortCallLog { log }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Успешный исход `start`: заданный `CaptureStarted`. Снимает ранее заданный отказ.
    public func setStartResult(_ started: CaptureStarted) {
        locked {
            startResult = started
            startFailure = nil
        }
    }

    /// Отказ `start` — любая `CaptureError`, включая `systemAudioPromptTimedOut` и
    /// `microphoneDenied`. Снимает ранее заданный успешный исход.
    public func failStart(with error: CaptureError) {
        locked {
            startFailure = error
            startResult = nil
        }
    }

    /// Манифест, который вернёт `stop`. Значение берётся у `RecordingManifestFixtures`.
    public func setStopManifest(_ manifest: RecordingManifest) {
        locked {
            stopManifest = manifest
            stopFailure = nil
        }
    }

    public func failStop(with error: CaptureError) {
        locked {
            stopFailure = error
            stopManifest = nil
        }
    }

    /// Манифест, который вернёт `recover(directory:)`, — в том числе уже восстановленный.
    public func setRecoverManifest(_ manifest: RecordingManifest) {
        locked {
            recoverManifest = manifest
            recoverFailure = nil
        }
    }

    /// Отказ восстановления; на нём стоит вторая ветвь К77.
    public func failRecover(with error: CaptureError) {
        locked {
            recoverFailure = error
            recoverManifest = nil
        }
    }

    /// Протолкнуть событие в поток. Значение не приводится ни к чему и доходит как есть.
    public func emit(_ event: CaptureEvent) {
        let targets = locked { continuations }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    /// Закрыть поток: подписчики досматривают выданное и выходят из цикла.
    public func finishEvents() {
        let targets = locked { () -> [AsyncStream<CaptureEvent>.Continuation] in
            let taken = continuations
            continuations = []
            return taken
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    /// Все вызовы с аргументами, в порядке совершения, — §«Фейк для тестов» C-004 дословно.
    public var recordedCalls: [CaptureCall] {
        locked { calls }
    }

    public func callCount(of predicate: (CaptureCall) -> Bool) -> Int {
        locked { calls }.filter(predicate).count
    }

    // MARK: - AudioCapturePort

    public func start(_ request: CaptureRequest) async throws -> CaptureStarted {
        log.record(
            port: Self.portName,
            method: "start(_:)",
            arguments: [request.recordingId.uuidString, request.meetingId?.uuidString ?? "nil"]
        )
        let outcome = locked { () -> (CaptureStarted?, CaptureError?) in
            calls.append(.start(request))
            return (startResult, startFailure)
        }
        if let failure = outcome.1 {
            throw failure
        }
        guard let started = outcome.0 else {
            throw CaptureError.systemUnavailable(message: "FakeAudioCapturePort: исход start не задан тестом")
        }
        return started
    }

    public func stop() async throws -> RecordingManifest {
        log.record(port: Self.portName, method: "stop()")
        let outcome = locked { () -> (RecordingManifest?, CaptureError?) in
            calls.append(.stop)
            return (stopManifest, stopFailure)
        }
        if let failure = outcome.1 {
            throw failure
        }
        guard let manifest = outcome.0 else {
            throw CaptureError.systemUnavailable(message: "FakeAudioCapturePort: манифест stop не задан тестом")
        }
        return manifest
    }

    public func pause() async throws {
        log.record(port: Self.portName, method: "pause()")
        locked { calls.append(.pause) }
    }

    public func resume() async throws {
        log.record(port: Self.portName, method: "resume()")
        locked { calls.append(.resume) }
    }

    public func setInput(_ selection: InputSelection) async throws {
        log.record(port: Self.portName, method: "setInput(_:)", arguments: [String(describing: selection)])
        locked { calls.append(.setInput(selection)) }
    }

    public func events() -> AsyncStream<CaptureEvent> {
        log.record(port: Self.portName, method: "events()")
        return AsyncStream { continuation in
            locked { continuations.append(continuation) }
        }
    }

    public func recover(directory: URL) async throws -> RecordingManifest {
        log.record(port: Self.portName, method: "recover(directory:)", arguments: [directory.lastPathComponent])
        let outcome = locked { () -> (RecordingManifest?, CaptureError?) in
            calls.append(.recover(directory: directory))
            return (recoverManifest, recoverFailure)
        }
        if let failure = outcome.1 {
            throw failure
        }
        guard let manifest = outcome.0 else {
            throw CaptureError.systemUnavailable(message: "FakeAudioCapturePort: манифест recover не задан тестом")
        }
        return manifest
    }
}
