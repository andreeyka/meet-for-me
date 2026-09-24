//  AudioCaptureImpl — единственный публичный тип модуля `capture`, реализация `AudioCapturePort`
//  (C-004 v6, MEE-77) по перечню критериев MEE-310 и плану MEE-315.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Единственный собственный публичный тип (инвариант 25: «хотя бы один» — реализацию создаёт
//  composition root в `App/`, и вывести наружу его нечем иначе). Публичные сигнатуры несут
//  только позиции разрешённого списка инварианта 25 — сверка поимённо в отчёте задачи (план
//  MEE-315 не закрывает её сборкой, «Что зелёный прогон не доказывает», пункт 1).
//
//  Устройство — `@unchecked Sendable` с `NSLock` вокруг фазы сеанса, тот же приём, что у
//  `SignalEngine` (Detector) и фейков `DomainTestKit`: протокол объявлен `Sendable`, а
//  `events()` синхронен, актором его не покрыть. Замок никогда не держится через `await` —
//  переходы фазы синхронны, асинхронная работа (гонка права, сборка агрегата) идёт между ними.

import DomainCore
import Foundation

/// Фаза сеанса. `alreadyRunning`/`notRunning` (инвариант 1) читаются по ней, а не по наличию
/// `CaptureSessionState`: во время `.starting` состояния ещё нет, а второй `start` уже обязан
/// отказать.
enum CapturePhase {
    case idle
    case starting
    case running(CaptureSessionState)
    case stopping
}

public final class AudioCaptureImpl: AudioCapturePort, @unchecked Sendable {

    let gateway: HardwareGateway
    let deadline: PromptDeadline
    let pollDriver: CapturePollDriver
    let power: PowerPort

    let lock = NSLock()
    var phase: CapturePhase = .idle
    var pollHandle: CapturePollDriverHandle?
    /// Подписка на `power.events()` — заведена один раз на всю жизнь порта (`installPowerEventsIfNeeded`),
    /// не на сеанс: `AudioCaptureImpl` переживает несколько сеансов подряд (инвариант 23), и
    /// пересоздавать её незачем — обработчик сам бьёт по текущей фазе на каждое событие.
    var powerEventsTask: Task<Void, Never>?
    var powerEventsInstalled = false

    let eventsLock = NSLock()
    var eventContinuations: [UUID: AsyncStream<CaptureEvent>.Continuation] = [:]

    /// Инициализатор для тестов и для харнесса-писателя (план MEE-315 §6): все швы подставные.
    init(power: PowerPort, gateway: HardwareGateway, deadline: PromptDeadline, pollDriver: CapturePollDriver) {
        self.power = power
        self.gateway = gateway
        self.deadline = deadline
        self.pollDriver = pollDriver
    }

    /// Продовый инициализатор: единственное место, где швы связаны с настоящей системой.
    /// `power` реализацией не владеет (карта модулей: `capture` потребляет `PowerPort`,
    /// реализует его модуль `permissions`) — composition root `App/` передаёт готовый порт.
    /// `PowerPort` в списке инварианта 25 — C-004 v5 (IR-112, MEE-325, закрыт).
    public convenience init(power: PowerPort) {
        self.init(power: power, gateway: CoreAudioGateway(), deadline: SystemPromptDeadline(),
                  pollDriver: SystemPollDriver())
    }

    // MARK: - AudioCapturePort

    public func start(_ request: CaptureRequest) async throws -> CaptureStarted {
        guard request.group != nil || request.input != .none else {
            throw CaptureError.nothingToCapture
        }
        try beginStarting()
        do {
            let (session, started) = try await performStart(request)
            commitRunning(session)
            emit(.started(started))
            return started
        } catch {
            resetToIdle()
            throw error
        }
    }

    public func events() -> AsyncStream<CaptureEvent> {
        AsyncStream { continuation in
            let id = UUID()
            eventsLock.lock()
            eventContinuations[id] = continuation
            eventsLock.unlock()
            continuation.onTermination = { [weak self] _ in
                self?.eventsLock.lock()
                self?.eventContinuations.removeValue(forKey: id)
                self?.eventsLock.unlock()
            }
        }
    }

    // MARK: - Внутреннее: фаза

    func beginStarting() throws {
        lock.lock(); defer { lock.unlock() }
        guard case .idle = phase else { throw CaptureError.alreadyRunning }
        phase = .starting
    }

    func resetToIdle() {
        lock.lock(); phase = .idle; lock.unlock()
    }

    func commitRunning(_ session: CaptureSessionState) {
        lock.lock()
        phase = .running(session)
        lock.unlock()
        let handle = pollDriver.start(seconds: AudioCaptureLimits.capturedProcessesPollSeconds) { [weak self] in
            self?.pollCapturedProcesses()
        }
        lock.lock(); pollHandle = handle; lock.unlock()
    }

    /// Достаёт текущий сеанс либо кидает `notRunning` (инвариант 1) — общая точка входа для
    /// `stop`/`pause`/`resume`/`setInput`.
    func currentSession() throws -> CaptureSessionState {
        lock.lock(); defer { lock.unlock() }
        guard case .running(let session) = phase else { throw CaptureError.notRunning }
        return session
    }

    /// Публикует событие всем живым подписчикам `events()` (инвариант 23: поток переживает
    /// сеанс, подписчиков может быть несколько).
    func emit(_ event: CaptureEvent) {
        eventsLock.lock()
        let targets = Array(eventContinuations.values)
        eventsLock.unlock()
        for continuation in targets {
            continuation.yield(event)
        }
    }
}
