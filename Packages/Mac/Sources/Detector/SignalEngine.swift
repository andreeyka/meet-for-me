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
//  Шаг наблюдения `step()` берёт у источника пару «содержание + момент» (Ш4, свойства (i) и
//  (ii)), а показание часов (Ш6) берёт отдельно — и это ДВЕ РАЗНЫЕ величины, а не одна:
//  момент снимка уезжает в `observedAt` сигналов и группы, показание часов отвечает на вопрос
//  «сколько сейчас», когда решается срок подтверждения. Отсчитывается срок от `observedAt`
//  прошлой публикации пары, а не от показания часов того шага, который её опубликовал:
//  координата публикации в C-009 одна (`ConfirmationPolicy`, инварианты 24 и 25). Шаг
//  возвращает управление, когда всё, что снимок должен был породить, уже отдано подписчикам.

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
    /// Что пара отдала в поток в последний раз. Срок подтверждения отсчитывается от
    /// `observedAt` этого сигнала — единственной временной координаты публикации, какую знает
    /// C-009. Показание часов того шага, который сигнал опубликовал, здесь не держится: после
    /// перехода на `observedAt` у него не осталось ни одного читателя, а хранимое значение без
    /// читателя возвращает то самое прочтение, от которого модуль уходит (MEE-267).
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
        let taken = try environment.source.readSnapshot()
        return SnapshotBuilder.audioProcesses(from: taken.content, observedAt: taken.observedAt)
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
        let taken = try environment.source.readSnapshot()
        let snapshot = SnapshotBuilder.audioProcesses(from: taken.content, observedAt: taken.observedAt)
        let candidates = SignalCandidates.make(from: snapshot, tables: tables, values: values,
                                               at: taken.observedAt)
        publish(candidates, at: environment.clock.now())
    }

    /// `moment` здесь — момент ПУБЛИКАЦИИ: показание часов наблюдения, а не момент снимка.
    /// В `observedAt` сигнала он не попадает ни одним путём — там стоит момент, пришедший
    /// входом вместе с содержанием снимка. Решению о сроке он даёт «сейчас»: часы Ш6 из
    /// решения не уходят, уходит только нижний конец отсчёта — им стал `observedAt` прошлой
    /// публикации пары.
    private func publish(_ candidates: [SignalCandidate], at moment: Date) {
        withState {
            var current: [PairKey: MeetingSignal] = [:]
            for candidate in candidates {
                if let previous = lastPublished[candidate.key],
                   previous.hasSameState(as: candidate.signal),
                   !ConfirmationPolicy.isDue(lastObservedAt: previous.observedAt, now: moment,
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
