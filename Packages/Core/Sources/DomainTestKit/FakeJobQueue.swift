//  FakeJobQueue — реализация `JobQueue`, которая ничего не исполняет. C-013 §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Состав управляющей поверхности — §«Фейк для тестов» C-013 дословно: «записывает все
//  `submit` и `cancel`, отдаёт их тесту списком и позволяет вручную протолкнуть любой
//  `JobEvent`». Плюс условие `С` плана MEE-288 §2: ЗАДАНИЕ СОСТАВА ЗАДАЧ через `jobs(status:)`
//  и РАЗРЕШЕНИЕ `jobId` → `Job.payload` через `job(id:)`.
//
//  ФЕЙК НЕ СОБИРАЕТ `Job` ИЗ `JobSubmission`, И ЭТО РЕШЕНИЕ С ДОВОДОМ, А НЕ НЕДОДЕЛКА.
//  Чтобы `submit` завёл строку, фейку пришлось бы вывести `Job.type` из `JobPayload` — то
//  есть написать тело `JobPayload.type`, которое П4 держит (MEE-290 §2: пять функций
//  контрактов не писать). Отображение выглядит однозначным, и ровно поэтому его здесь нет:
//  написать его в фейке значит ответить за контракт молча, у которого нет ни перечня
//  критериев, ни плана. Поэтому состав задач ЗАДАЁТ ТЕСТ — `setJobs(_:)`, — а `submit`
//  записывает поданное и отдаёт идентификатор.
//
//  ИДЕНТИФИКАТОРЫ `submit` ДЕТЕРМИНИРОВАНЫ: по умолчанию счётчиком
//  (`00000000-0000-0000-0000-<номер>`), и тест вправе задать их наперёд `setNextSubmitIds(_:)`
//  — тогда он знает идентификатор ДО вызова и может засеять под него `Job`. Случайный `UUID()`
//  сделал бы ответ фейка невоспроизводимым между прогонами.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ОЧЕРЕДИ: ни один инвариант C-013 он не держит — ни дедупликацию
//  по `dedupKey` (инвариант 1), ни условия запуска, ни лизинг, ни откат. `start()` и `stop()`
//  не запускают и не останавливают ничего: исполнять ему нечего.
//
//  `@unchecked Sendable` с замком, а не актор: `JobQueue` объявлен `: Sendable`,
//  а `events()` синхронен, и актором протокол не покрыть.

import Foundation
import DomainCore

/// Фейк очереди задач. Всё поведение задаёт тест.
public final class FakeJobQueue: JobQueue, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "JobQueue"

    private let lock = NSLock()
    private let log: PortCallLog

    private var submitted: [JobSubmission] = []
    private var cancelled: [UUID] = []
    private var registered: [JobType] = []
    private var jobsById: [UUID: Job] = [:]
    private var jobOrder: [UUID] = []
    private var plannedIds: [UUID] = []
    private var nextNumber = 1
    private var startCalls = 0
    private var stopCalls = 0
    private var recordingDidStartCalls = 0
    private var recordingDidStopCalls = 0
    private var submitFailure: JobQueueError?
    private var continuations: [AsyncStream<JobEvent>.Continuation] = []

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

    /// Задать состав задач — условие `С`. Порядок сохраняется: `jobs(status:)` отдаёт
    /// подходящие в том порядке, в каком их задали.
    public func setJobs(_ list: [Job]) {
        locked {
            for job in list {
                if jobsById[job.id] == nil {
                    jobOrder.append(job.id)
                }
                jobsById[job.id] = job
            }
        }
    }

    /// Задать наперёд идентификаторы, которые вернут следующие вызовы `submit`.
    /// Кончились заданные — фейк продолжает счётчиком.
    public func setNextSubmitIds(_ list: [UUID]) {
        locked { plannedIds = list }
    }

    /// Идентификатор, который `submit` вернёт `n`-м по счёту, если наперёд ничего не задано.
    public static func deterministicId(_ number: Int) -> UUID {
        InMemoryTranscriptRepository.deterministicId(number)
    }

    /// Заставить `submit` бросить заданную ошибку; `nil` снимает отказ.
    public func failSubmit(with error: JobQueueError?) {
        locked { submitFailure = error }
    }

    /// Протолкнуть событие в поток. Значение не приводится ни к чему и доходит как есть.
    public func emit(_ event: JobEvent) {
        let targets = locked { continuations }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    /// Закрыть поток: подписчики досматривают выданное и выходят из цикла.
    public func finishEvents() {
        let targets = locked { () -> [AsyncStream<JobEvent>.Continuation] in
            let taken = continuations
            continuations = []
            return taken
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    /// Все `submit` в порядке подачи — §«Фейк для тестов» C-013 дословно.
    public var submissions: [JobSubmission] {
        locked { submitted }
    }

    /// Все `cancel` в порядке подачи.
    public var cancellations: [UUID] {
        locked { cancelled }
    }

    /// Типы, под которые зарегистрированы обработчики, в порядке регистрации.
    public var registeredHandlerTypes: [JobType] {
        locked { registered }
    }

    public var startCallCount: Int { locked { startCalls } }
    public var stopCallCount: Int { locked { stopCalls } }
    public var recordingDidStartCallCount: Int { locked { recordingDidStartCalls } }
    public var recordingDidStopCallCount: Int { locked { recordingDidStopCalls } }

    // MARK: - JobQueue

    public func register(handler: JobHandler) async throws {
        let type = handler.type
        log.record(port: Self.portName, method: "register(handler:)", arguments: [type.rawValue])
        let clash = locked { () -> Bool in
            guard !registered.contains(type) else { return true }
            registered.append(type)
            return false
        }
        if clash {
            throw JobQueueError.handlerAlreadyRegistered(type)
        }
    }

    public func submit(_ submission: JobSubmission) async throws -> UUID {
        log.record(
            port: Self.portName,
            method: "submit(_:)",
            arguments: [String(describing: submission.payload), submission.dedupKey ?? "nil"]
        )
        if let failure = locked({ submitFailure }) {
            throw failure
        }
        return locked { () -> UUID in
            submitted.append(submission)
            if plannedIds.isEmpty {
                let identifier = Self.deterministicId(nextNumber)
                nextNumber += 1
                return identifier
            }
            return plannedIds.removeFirst()
        }
    }

    public func cancel(jobId: UUID) async throws {
        log.record(port: Self.portName, method: "cancel(jobId:)", arguments: [jobId.uuidString])
        // Вызов записывается ВСЕГДА, и `unknownJob` фейк не бросает ни на одном входе:
        // отмена задачи, состава которой тест не задавал, есть незаполненный фейк, а не
        // утверждение об очереди. Заставить `cancel` отказать тест может тем же способом,
        // каким это делают другие фейки, — и такого способа здесь нет намеренно: ни один
        // пункт плана на отказе `cancel` не стоит.
        locked { cancelled.append(jobId) }
    }

    public func job(id: UUID) async throws -> Job? {
        log.record(port: Self.portName, method: "job(id:)", arguments: [id.uuidString])
        return locked { jobsById[id] }
    }

    public func jobs(status: JobStatus) async throws -> [Job] {
        log.record(port: Self.portName, method: "jobs(status:)", arguments: [status.rawValue])
        return locked {
            jobOrder
                .compactMap { jobsById[$0] }
                .filter { $0.status == status }
        }
    }

    public func start() async {
        log.record(port: Self.portName, method: "start()")
        locked { startCalls += 1 }
    }

    public func stop() async {
        log.record(port: Self.portName, method: "stop()")
        locked { stopCalls += 1 }
    }

    public func events() -> AsyncStream<JobEvent> {
        log.record(port: Self.portName, method: "events()")
        return AsyncStream { continuation in
            locked { continuations.append(continuation) }
        }
    }

    /// C-013 v9 — часть протокола `JobQueue`. Фейк не эталон поведения (шапка файла):
    /// счётчик считает вызов, ничего не пересматривает и не хранит факт записи.
    public func recordingDidStart() async {
        log.record(port: Self.portName, method: "recordingDidStart()")
        locked { recordingDidStartCalls += 1 }
    }

    public func recordingDidStop() async {
        log.record(port: Self.portName, method: "recordingDidStop()")
        locked { recordingDidStopCalls += 1 }
    }
}
