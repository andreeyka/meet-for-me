//  CapturePromptRace — гонка «исход шва» против «предел ожидания», без отмены исхода.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Контракт C-004 §«Право на системный звук», п. 3, и §«Микрофонный промпт», п. 3— дословно:
//  «Промпт при этом остаётся на экране: отменить его нечем... Реализация обязана дождаться
//  отложенного ответа на своём потоке». Значит по истечении предела исход НЕ отменяется — он
//  продолжает исполняться, и `start()` обязан вернуться раньше него. `withTaskGroup` для этого
//  не годится: выход из его области ждёт всех дочерних задач, а не только первую готовую, —
//  ранний возврат при таймауте забрал бы с собой отмену (`cancelAll`) незавершённой попытки,
//  а с ней и исход, который контракт требует дождаться отдельно. Поэтому попытка живёт
//  собственной задачей `Task`, не дочерней задаче группы, а гонка собрана вручную через
//  continuation, резюмируемый ровно один раз — тем, кто пришёл первым.
struct PromptRaceResult<Value: Sendable>: Sendable {
    enum Outcome: Sendable {
        case value(Value)
        case timedOut
    }
    let outcome: Outcome
    /// Задача исхода — живёт и после таймаута; вызывающая сторона обязана её дождаться
    /// в фоне (см. `AudioCaptureImpl.handleLateOutcome`).
    let pending: Task<Value, Never>
}

/// Резюмирует continuation ровно один раз — второй и следующие вызовы игнорируются. Один
/// экземпляр на одну гонку; создаётся и живёт внутри `race(timeoutSeconds:deadline:operation:)`.
private final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<PromptRaceResult<Value>.Outcome, Never>?

    init(_ continuation: CheckedContinuation<PromptRaceResult<Value>.Outcome, Never>) {
        self.continuation = continuation
    }

    func resume(with outcome: PromptRaceResult<Value>.Outcome) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: outcome)
    }
}

/// Гонит `operation()` против `deadline.wait(seconds: timeoutSeconds)`. `operation` не
/// отменяется по таймауту (см. доку типа выше) — её задача возвращается в `pending` для
/// досмотра вызывающей стороной.
func race<Value: Sendable>(
    timeoutSeconds: Int,
    deadline: PromptDeadline,
    operation: @escaping @Sendable () async -> Value
) async -> PromptRaceResult<Value> {
    let pending = Task<Value, Never> { await operation() }
    typealias Continuation = CheckedContinuation<PromptRaceResult<Value>.Outcome, Never>
    let outcome = await withCheckedContinuation { (continuation: Continuation) in
        let once = ResumeOnce(continuation)
        Task {
            let value = await pending.value
            once.resume(with: .value(value))
        }
        Task {
            await deadline.wait(seconds: timeoutSeconds)
            once.resume(with: .timedOut)
        }
    }
    return PromptRaceResult(outcome: outcome, pending: pending)
}
