//  SignalEngine — наблюдение и поток `signals()`. C-009 §«Поведение»; инварианты 11, 13, 24.
//
//  * Сигнал публикуется при изменении состояния пары «вид + источник», а пока состояние
//    держится — подтверждается публикацией до истечения `signalTtlSeconds` (инвариант 24,
//    срок — `ConfirmationPolicy`). Раньше срока неизменившееся состояние в поток не идёт;
//    изменившийся состав `group.pids` идёт сразу. Состояния, которого больше нет, подтверждать
//    нечем: публикации прекращаются, «выключенного» сигнала нет.
//  * Поток отдаёт события после подписки; наблюдение переживает отсутствие подписчиков.
//  * `startObserving()` идемпотентен: второй вызов при идущем наблюдении не заводит второго
//    драйвера (инвариант 13).
//  * Смерть процесса — не ошибка: следующий снимок просто не содержит его `pid`.
//
//  Шаг наблюдения `step()` берёт снимок у источника (Ш4) и момент у часов (Ш6) и возвращает
//  управление, когда всё, что снимок должен был породить, уже отдано подписчикам.

import DomainCore
import Foundation

final class SignalEngine: @unchecked Sendable {

    /// Внешний мир наблюдения: источник снимков, часы и драйвер шагов.
    struct Environment: Sendable {
        let source: ProcessSnapshotSource
        let clock: ObservationClock
        let driver: ObservationDriver
        /// Шаг, с которым наблюдение хочет замечать изменения, если срок позволяет.
        let preferredStep: TimeInterval
    }

    private let tables: RuleTables
    private let values: ReceivedValues
    private let environment: Environment

    private let stepLock = NSLock()
    private let stateLock = NSLock()
    private var subscribers: [UUID: AsyncStream<MeetingSignal>.Continuation] = [:]
    private var lastPublished: [PairKey: MeetingSignal] = [:]
    private var observing = false

    init(tables: RuleTables, values: ReceivedValues, environment: Environment) {
        self.tables = tables
        self.values = values
        self.environment = environment
    }

    deinit {
        environment.driver.stop()
        finishSignalStreams()
    }

    // MARK: - Снимок

    func audioProcesses() throws -> [AudioProcess] {
        let snapshot = try environment.source.readSnapshot()
        return SnapshotBuilder.audioProcesses(from: snapshot, observedAt: environment.clock.now())
    }

    // MARK: - Поток

    func signals() -> AsyncStream<MeetingSignal> {
        let id = UUID()
        return AsyncStream { continuation in
            withState { subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.withState { self?.subscribers[id] = nil }
            }
        }
    }

    /// Завершает все выданные потоки. Зовётся при уничтожении и тестом — чтобы прочитать поток
    /// до конца и увидеть в нём ровно то, что было опубликовано.
    func finishSignalStreams() {
        let finishing = withState { () -> [AsyncStream<MeetingSignal>.Continuation] in
            defer { subscribers = [:] }
            return Array(subscribers.values)
        }
        finishing.forEach { $0.finish() }
    }

    // MARK: - Наблюдение

    func startObserving() throws {
        let alreadyObserving = withState { () -> Bool in
            defer { observing = true }
            return observing
        }
        guard !alreadyObserving else { return }
        do {
            try step()
        } catch {
            stopObserving()
            throw error
        }
        let interval = ConfirmationPolicy.step(preferred: environment.preferredStep,
                                               signalTtlSeconds: values.signalTtlSeconds)
        environment.driver.start(interval: interval) { [weak self] in
            try? self?.step()
        }
    }

    func stopObserving() {
        environment.driver.stop()
        stepLock.lock()
        defer { stepLock.unlock() }
        withState {
            observing = false
            lastPublished = [:]
        }
    }

    /// Один шаг наблюдения: снимок, сигналы, публикация изменений и подтверждений.
    func step() throws {
        stepLock.lock()
        defer { stepLock.unlock() }
        guard withState({ observing }) else { return }
        let moment = environment.clock.now()
        let snapshot = SnapshotBuilder.audioProcesses(from: try environment.source.readSnapshot(),
                                                      observedAt: moment)
        let candidates = SignalCandidates.make(from: snapshot, tables: tables, values: values, at: moment)
        publish(candidates, at: moment)
    }

    private func publish(_ candidates: [SignalCandidate], at moment: Date) {
        withState {
            var current: [PairKey: MeetingSignal] = [:]
            for candidate in candidates {
                if let previous = lastPublished[candidate.key], previous.hasSameState(as: candidate.signal),
                   !ConfirmationPolicy.isDue(published: previous.observedAt, now: moment,
                                             signalTtlSeconds: values.signalTtlSeconds) {
                    current[candidate.key] = previous
                    continue
                }
                current[candidate.key] = candidate.signal
                subscribers.values.forEach { $0.yield(candidate.signal) }
            }
            lastPublished = current
        }
    }

    private func withState<Value>(_ body: () throws -> Value) rethrows -> Value {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}
