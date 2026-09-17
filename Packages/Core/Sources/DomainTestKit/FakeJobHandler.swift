//  FakeJobHandler — обработчик заданного типа, C-013 §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Состав взят у контракта дословно, включая дополнение v4: «обработчик заданного типа,
//  возвращающий заданный `JobOutcome`, умеющий „работать долго“ (для проверки отмены и
//  лизинга) и считающий число исполнений (для проверки инварианта 6)»; «`FakeJobHandler`
//  дополнительно ОТДАЁТ ТЕСТУ СТРОКУ ЗАДАЧИ В МОМЕНТ ВЫЗОВА `run` — иначе „отметка
//  поставлена ДО вызова, а не после“ утверждением не является».
//
//  §6 ПЛАНА MEE-288 ЭТОГО ФЕЙКА НЕ НАЗЫВАЕТ ВОВСЕ — ни в таблице восьми средств, ни в
//  перечислении «что пришлось бы завести». Найден чтением §«Фейк для тестов» C-013, где он
//  стоит отдельным абзацем после трёх перечисленных. Находка названа в отчёте MEE-290.
//
//  «РАБОТАТЬ ДОЛГО» СДЕЛАНО СНОМ НА ЗАДАННЫЙ ТЕСТОМ СРОК, а не бесконечным циклом: сон
//  снимается отменой задачи, и ветка «обработчик отменён посреди работы» наблюдается тем,
//  что `run` вернулся раньше срока. Бесконечный цикл отменяемость проверял бы собой.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ОБРАБОТЧИКА: инвариант 6 C-013 — обязанность очереди, и этот
//  счётчик есть НАБЛЮДАЕМОСТЬ для её теста, а не её проверка.

import Foundation
import DomainCore

/// Обработчик задач, полностью управляемый тестом.
public final class FakeJobHandler: JobHandler, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "JobHandler"

    public let type: JobType

    private let lock = NSLock()
    private let log: PortCallLog

    private var outcome: JobOutcome = .success
    private var progressSteps: [Double] = []
    private var workSeconds: Double = 0
    private var runs: [Job] = []

    /// - Parameters:
    ///   - type: тип задач, которые обработчик берёт.
    ///   - log: общий журнал вызовов (условие `Н`). Не дали — фейк заводит свой.
    public init(type: JobType, log: PortCallLog = PortCallLog()) {
        self.type = type
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

    /// Исход, который вернёт `run`. Умолчание — `.success`.
    public func setOutcome(_ value: JobOutcome) {
        locked { outcome = value }
    }

    /// Доли, которые `run` отдаст в `progress` по порядку, прежде чем вернуть исход.
    public func setProgressSteps(_ steps: [Double]) {
        locked { progressSteps = steps }
    }

    /// «Работать долго»: `run` спит столько секунд, прежде чем вернуть исход. Ноль — не спит.
    /// Отмена задачи сон прерывает, и `run` возвращает заданный исход раньше срока.
    public func workLong(seconds: Double) {
        locked { workSeconds = seconds }
    }

    /// Строки задач в том виде, в каком они пришли в `run`, в порядке вызовов.
    /// Дополнение v4 контракта: без этого «отметка поставлена до вызова» не утверждение.
    public var observedJobs: [Job] {
        locked { runs }
    }

    /// Число исполнений — инвариант 6 C-013 наблюдается им.
    public var runCallCount: Int {
        locked { runs.count }
    }

    // MARK: - JobHandler

    public func run(
        _ job: Job,
        progress: @Sendable @escaping (Double) -> Void
    ) async -> JobOutcome {
        log.record(
            port: Self.portName,
            method: "run(_:progress:)",
            arguments: [job.id.uuidString, job.type.rawValue, String(job.attempts)]
        )
        let plan = locked { () -> RunPlan in
            runs.append(job)
            return RunPlan(outcome: outcome, steps: progressSteps, seconds: workSeconds)
        }
        for step in plan.steps {
            progress(step)
        }
        if plan.seconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(plan.seconds * 1_000_000_000))
        }
        return plan.outcome
    }

    /// Снимок заданного тестом поведения, снятый под замком одним куском: три значения
    /// структурой, а не кортежем, — кортеж из трёх членов ловит `large_tuple`.
    private struct RunPlan {
        let outcome: JobOutcome
        let steps: [Double]
        let seconds: Double
    }
}
