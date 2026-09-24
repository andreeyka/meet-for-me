//  JobQueueEngine — реализация `JobQueue` (C-013 v9, MEE-21) поверх `JobRepository`. MEE-350.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  «Поведение» C-013 требует прямо: «`JobQueue` и `JobRepository` — `Sendable`; реализация
//  очереди изолирована актором» — отсюда `actor`, а не класс с замком, как у фейков.
//
//  Файл несёт состояние, инициализатор и методы протокола без времени жизни очереди
//  (`register`, `submit`, `cancel`, `job`, `jobs`, `events`) — жизненный цикл (`start`/`stop`,
//  `recordingDidStart`/`recordingDidStop`, восстановление по инвариантам 10/11) в
//  `JobQueueEngineLifecycle.swift`, пересмотр §7 в `JobQueueEngineReview.swift`, исполнение
//  обработчика и лизинг в `JobQueueEngineExecution.swift` — деление по объёму
//  (`file_length`/`type_body_length` SwiftLint), одна и та же расширяемая сущность
//  `JobQueueEngine`.
//
//  `recordingDidStart()`/`recordingDidStop()` (инвариант 4, `JobBlockReason.
//  recordingInProgress`) были взяты по конвенции у конкретного типа (// СТРОКА, снята
//  возвратом РП на MEE-350) — C-013 v9 объявил их дословно в протоколе `JobQueue`; здесь
//  осталась только реализация.

import Foundation

public actor JobQueueEngine: JobQueue {

    let repository: JobRepository
    let modelCatalog: ModelCatalogPort
    let powerPort: PowerPort
    let clock: @Sendable () -> Date
    let leaseSeconds: Int
    let globalConcurrencyLimit: Int
    let perTypeConcurrencyLimit: Int

    var handlers: [JobType: JobHandler] = [:]
    /// Задачи, ФАКТИЧЕСКИ переданные обработчику — то есть с уже поставленной отметкой
    /// начала попытки. Кандидат, взятый `claimNext` и ещё не дошедший до шага 4 §7, в этом
    /// множестве не числится (инвариант 12 отличает их этим же признаком). Тип задачи несётся
    /// рядом с `Task`, чтобы предел `maxConcurrent` (§4) считался без обращения к репозиторию.
    var runningTasks: [UUID: RunningEntry] = [:]
    /// Идентификаторы, для которых `cancel` запросил отмену исполняемой задачи — снимается,
    /// когда исполнение фактически вернулось (инвариант 8: «после его возврата, а не до»).
    var cancellationRequested: Set<UUID> = []

    var isRunning = false
    var isRecordingInProgress = false
    var timerTask: Task<Void, Never>?
    var powerEventsTask: Task<Void, Never>?

    /// `nonisolated`: `events()` (§2) не `async` в контракте и обязан быть вызываем без
    /// изоляции актора; хранилище подписчиков поэтому читается отсюда напрямую.
    nonisolated let broadcaster = JobEventBroadcaster()

    /// - Parameters:
    ///   - leaseSeconds: срок лизинга, взятого `claimNext`. Контракт числа не называет —
    ///     называет только нижнюю границу продления, «не реже раза в 30 секунд» (инвариант
    ///     11) — здесь взято вдвое больше периода продления, чтобы одно пропущенное
    ///     продление не роняло лизинг немедленно.
    ///   - globalConcurrencyLimit: §4, «Глобальный предел одновременно исполняемых задач — 2».
    ///   - perTypeConcurrencyLimit: §4, «Пределы `maxConcurrent` по типам умышленно равны 1».
    public init(
        repository: JobRepository,
        modelCatalog: ModelCatalogPort,
        powerPort: PowerPort,
        clock: @escaping @Sendable () -> Date,
        leaseSeconds: Int = 60,
        globalConcurrencyLimit: Int = 2,
        perTypeConcurrencyLimit: Int = 1
    ) {
        self.repository = repository
        self.modelCatalog = modelCatalog
        self.powerPort = powerPort
        self.clock = clock
        self.leaseSeconds = leaseSeconds
        self.globalConcurrencyLimit = globalConcurrencyLimit
        self.perTypeConcurrencyLimit = perTypeConcurrencyLimit
    }

    /// Без этого `timerTask`/`powerEventsTask` не запертого `stop()`-ом актора (в тесте,
    /// не вызвавшем его, — легальный вход: `stop()` не часть готовности каждого теста)
    /// переживают сам актор: `[weak self]` внутри них не разрывает `for await` над
    /// `AsyncStream`, чья `Continuation` при этом молча деинициализируется вместе с
    /// `FakePowerPort`, ничего не подавая, — та же задача остаётся подвешенной НАВСЕГДА
    /// (`AsyncStream.Continuation` без явного `finish()` итерацию не завершает). Найдено
    /// прогонами CI на этой ветке: сотни таких зависших `for await` от тестов без `stop()`
    /// копятся в процессе `swift test` и, начиная с некоторого числа, останавливают
    /// планировщик Swift Concurrency целиком — зависание проявляется в СЛУЧАЙНОМ, не
    /// обязательно моём, тесте (симптом наблюдался и в тестах вне DomainCore/JobQueue).
    /// `cancel()` здесь не изолирован актором и потому легален в `deinit`.
    deinit {
        timerTask?.cancel()
        powerEventsTask?.cancel()
    }

    // MARK: - §2, регистрация

    public func register(handler: JobHandler) throws {
        guard handlers[handler.type] == nil else {
            throw JobQueueError.handlerAlreadyRegistered(handler.type)
        }
        handlers[handler.type] = handler
    }

    // MARK: - §1, постановка и дедуп (инварианты 1, 2, 22, 27)

    public func submit(_ submission: JobSubmission) async throws -> UUID {
        guard submission.priority >= -100, submission.priority <= 100 else {
            throw JobQueueError.invalidPriority(submission.priority)
        }
        if let dedupKey = submission.dedupKey,
           let existing = try await performWithRepair({ try await self.repository.activeJob(dedupKey: dedupKey) }) {
            return existing.id
        }
        let now = clock()
        let job = Job(
            id: UUID(), type: submission.payload.type, payload: submission.payload, status: .pending,
            priority: submission.priority, attempts: 0, maxAttempts: submission.maxAttempts,
            runAfter: submission.runAfter, conditions: submission.conditions, dedupKey: submission.dedupKey,
            leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil, createdAt: now, updatedAt: now
        )
        try await repository.insert(job)
        broadcaster.publish(.submitted(jobId: job.id, type: job.type))
        if isRunning {
            await runRevisitPass()
        }
        return job.id
    }

    // MARK: - Отмена (инварианты 8, 9)

    public func cancel(jobId: UUID) async throws {
        guard let job = try await performWithRepair({ try await self.repository.job(id: jobId) }) else {
            throw JobQueueError.unknownJob(jobId)
        }
        switch job.status {
        case .pending:
            try await repository.update(job.cancellingWithoutExecution(now: clock()))
            broadcaster.publish(.cancelled(jobId: job.id, type: job.type))
        case .running:
            cancellationRequested.insert(jobId)
            runningTasks[jobId]?.task.cancel()
        case .succeeded, .failed, .cancelled:
            break
        }
    }

    // MARK: - Точечное чтение

    public func job(id: UUID) async throws -> Job? {
        try await performWithRepair({ try await self.repository.job(id: id) })
    }

    /// Инвариант 32: нечитаемые строки наружу из очереди не выходят — при `pending`/`running`
    /// названные чинятся здесь же (§6, п. 5), а метод отдаёт `JobListing.jobs` без них.
    public func jobs(status: JobStatus) async throws -> [Job] {
        let listing = try await repository.jobs(status: status)
        guard status == .pending || status == .running, !listing.unreadable.isEmpty else {
            return listing.jobs
        }
        for row in listing.unreadable {
            let type = try await repository.failUnreadable(jobId: row.id, message: row.message, now: clock())
            if let type {
                broadcaster.publish(.failed(jobId: row.id, type: type, error: row.message, willRetry: false))
            }
        }
        return listing.jobs
    }

    public nonisolated func events() -> AsyncStream<JobEvent> {
        broadcaster.subscribe()
    }

    // MARK: - §6, ремонт нечитаемой строки — общий для всех бросающих методов порта

    /// Вызывает `operation`; на `StorageError.dataCorrupted(entity: "Job", ...)` чинит строку
    /// (`failUnreadable`, публикует `failed(willRetry: false)`, если строка правда переведена)
    /// и повторяет `operation`. Один и тот же `id` в пределах одного вызова обрабатывается не
    /// более одного раза (инвариант 24) — повторное появление того же `id` останавливает цикл,
    /// и отказ уходит вызывающей стороне (§6, п. 4). `entity != "Job"` либо `id`, не
    /// разбирающийся в `UUID`, — ремонт невозможен тем же путём.
    func performWithRepair<Value>(
        _ operation: () async throws -> Value
    ) async throws -> Value {
        var repaired: Set<UUID> = []
        while true {
            do {
                return try await operation()
            } catch StorageError.dataCorrupted(let entity, let idText, let message) {
                guard entity == "Job", let id = UUID(uuidString: idText), !repaired.contains(id) else {
                    throw StorageError.dataCorrupted(entity: entity, id: idText, message: message)
                }
                repaired.insert(id)
                let type = try await repository.failUnreadable(jobId: id, message: message, now: clock())
                if let type {
                    broadcaster.publish(.failed(jobId: id, type: type, error: message, willRetry: false))
                }
            }
        }
    }
}

/// Журнал подписчиков `events()` — `events()` не `async` в контракте (§2), а актор такой метод
/// обязан отдать `nonisolated`; состояние потому живёт в отдельном классе с замком, а не в
/// акторе, тем же приёмом, что у `PortCallLog`.
final class JobEventBroadcaster: @unchecked Sendable {

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<JobEvent>.Continuation] = [:]

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func subscribe() -> AsyncStream<JobEvent> {
        AsyncStream { continuation in
            let subscriptionId = UUID()
            locked { continuations[subscriptionId] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.locked { self.continuations[subscriptionId] = nil }
            }
        }
    }

    func publish(_ event: JobEvent) {
        let targets = locked { Array(continuations.values) }
        for continuation in targets {
            continuation.yield(event)
        }
    }
}
