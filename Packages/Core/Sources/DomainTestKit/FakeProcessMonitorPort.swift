//  FakeProcessMonitorPort — реализация `ProcessMonitorPort` в памяти, C-009 §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Управляется тестом целиком: список процессов задаётся и меняется на лету, в поток `signals()`
//  проталкивается ЛЮБОЙ `MeetingSignal` с любой `ProcessGroup`, `startObserving()` заставляется
//  бросить, вызовы считаются.
//
//  Слово «любой» здесь сознательное и держится шапкой раздела «Инварианты» [v5, IR-048]: фейк
//  не связан обязанностями публикующей стороны (инварианты 11, 12, 15, 17, 18), потому что его
//  значение — вход, выбранный тестом, а не утверждение о наблюдаемом мире. Поэтому сигнал,
//  который настоящий порт отдать не вправе, проходит здесь НЕИЗМЕНЁННЫМ: без этого ветку
//  «потребитель пережил негодный вход от сломанного адаптера» не проверить ничем.
//
//  Цена сказана там же и повторена здесь, потому что молчание о границе читается как её
//  отсутствие: ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА. Из того, что он отдаёт, не следует ни одного
//  разрешения реализатору `detector` — поведение порта описывает контракт, и только он.
//
//  `@unchecked Sendable` с замком, а не актор: `ProcessMonitorPort` объявлен `: Sendable`,
//  а его методы — не `async` целиком (`signals()` синхронен), и актором протокол не покрыть.

import Foundation
import DomainCore

/// Фейк порта наблюдения за процессами. Всё поведение задаёт тест.
public final class FakeProcessMonitorPort: ProcessMonitorPort, @unchecked Sendable {

    private let lock = NSLock()
    private var processes: [AudioProcess] = []
    private var continuations: [AsyncStream<MeetingSignal>.Continuation] = []
    private var startFailure: ProcessMonitorError?
    private var startCalls = 0
    private var stopCalls = 0

    public init() {}

    /// Замок вокруг состояния. Своя обёртка, а не `NSLocking.withLock`: та пришла в Foundation
    /// позже минимальной версии тулчейна, на которой собирается работа CI `Core (Linux)`.
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Задать или сменить снимок процессов на лету.
    public func setProcesses(_ list: [AudioProcess]) {
        locked { processes = list }
    }

    /// Протолкнуть сигнал в поток. Значение не приводится ни к чему и доходит как есть.
    public func emit(_ signal: MeetingSignal) {
        let targets = locked { continuations }
        for continuation in targets {
            continuation.yield(signal)
        }
    }

    /// Закрыть поток: подписчики досматривают выданное и выходят из цикла.
    public func finishSignals() {
        let targets = locked {
            let taken = continuations
            continuations = []
            return taken
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    /// Заставить `startObserving()` бросить названную ошибку; `nil` снимает отказ.
    public func failStartObserving(with error: ProcessMonitorError?) {
        locked { startFailure = error }
    }

    /// Счётчик вызовов `startObserving()`.
    public var startObservingCallCount: Int {
        locked { startCalls }
    }

    /// Счётчик вызовов `stopObserving()`.
    public var stopObservingCallCount: Int {
        locked { stopCalls }
    }

    // MARK: - ProcessMonitorPort

    public func audioProcesses() async throws -> [AudioProcess] {
        locked { processes }
    }

    /// Отбор по правилу §4.1 — той же чистой функцией, что и у настоящей реализации.
    public func processes(matching bundleIds: [String]) async throws -> [AudioProcess] {
        locked { processes }
            .filter { process in bundleIds.contains { bundleKeyMatches(appKey: process.appKey, entry: $0) } }
            .sorted { $0.pid < $1.pid }
    }

    public func signals() -> AsyncStream<MeetingSignal> {
        AsyncStream { continuation in
            locked { continuations.append(continuation) }
        }
    }

    public func startObserving() async throws {
        let failure = locked { () -> ProcessMonitorError? in
            startCalls += 1
            return startFailure
        }
        if let failure {
            throw failure
        }
    }

    public func stopObserving() async {
        locked { stopCalls += 1 }
    }
}
