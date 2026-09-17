//  JobQueue и её типы — контракт C-013 (MEE-21), «Определение», §§1—2
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-289, прецедент формы — MEE-86). Реализацию очереди пишет
//  `domain-core` отдельной задачей; фейков `FakeJobQueue`, `FakeJobHandler`,
//  `InMemoryJobRepository` и `ManualClock` в дереве нет — они предмет MEE-290 и дальше.
//
//  Состав взят из §§1—2 контракта целиком: план MEE-288 §6 назвал четыре типа
//  (Job, JobEvent, JobPayload, JobSubmission) и порт `JobQueue`, а «Определение»
//  объявляет в §§1—2 двенадцать имён, и без остальных семи ни одна подпись порта
//  не компилируется — начиная с `register(handler:)`, которому нужен `JobHandler`.
//
//  §3 «Хранилище задач» (`JobRepository`, `JobListing`, `UnreadableJobRow`) здесь НЕ
//  объявлен: §6 плана назвал шесть портов, и `JobRepository` среди них нет, а подписи
//  `JobQueue` его не требуют. Назван в отчёте MEE-289.
//
//  НЕ ОБЪЯВЛЕНЫ ТРИ ФУНКЦИИ КОНТРАКТА, И ЭТО РЕШЕНИЕ: `JobPayload.type`,
//  `JobPayload.profileId` и `JobSubmission.standard(_:runAfter:)`. Все три — тела, а не
//  типы: их ответ задают §1.1 и таблица §4, то есть поведение, которое MEE-289 писать
//  запрещено прямо. Цена названа в отчёте.
//
//  Порядок типов и порядок полей внутри типа — дословно по §§1—2 контракта
//  (порядок значим: правило обхода C-001 §0.2 п. 9).

import Foundation

// MARK: - §1. Задача

public enum JobType: String, Codable, Sendable, CaseIterable {
    case transcode    // PCM CAF → AAC m4a + 16 кГц моно-копии для движка
    case transcribe
    case diarize
    case attribute
    case summarize    // вне Среза 1: обработчик не регистрируется, задача не ставится
}

public enum JobPayload: Codable, Equatable, Sendable {
    case transcode(recordingId: UUID)
    case transcribe(recordingId: UUID, profileId: String, language: String?)
    case diarize(recordingId: UUID, profileId: String)
    case attribute(transcriptId: UUID, meetingId: UUID?)
    case summarize(meetingId: UUID, transcriptId: UUID, profileId: String)
}

public enum JobStatus: String, Codable, Sendable {
    case pending, running, succeeded, failed, cancelled
}

public struct JobConditions: Codable, Equatable, Sendable {
    public let requiresACPower: Bool
    public let forbidWhileRecording: Bool
    public let maxThermalPressure: ThermalPressure   // C-008; задача не стартует при более высоком
    public let requiresProfileReady: String?         // profileId (C-014); nil — условия нет (§1.1)

    public init(
        requiresACPower: Bool,
        forbidWhileRecording: Bool,
        maxThermalPressure: ThermalPressure,
        requiresProfileReady: String?
    ) {
        self.requiresACPower = requiresACPower
        self.forbidWhileRecording = forbidWhileRecording
        self.maxThermalPressure = maxThermalPressure
        self.requiresProfileReady = requiresProfileReady
    }
}

public struct Job: Codable, Equatable, Sendable {
    public let id: UUID
    public let type: JobType
    public let payload: JobPayload
    public let status: JobStatus
    public let priority: Int          // больше — раньше; допустимый диапазон -100...100
    public let attempts: Int          // сколько попыток уже сделано
    public let maxAttempts: Int
    public let runAfter: Date         // раньше этого момента задача не берётся
    public let conditions: JobConditions
    public let dedupKey: String?
    public let leaseExpiresAt: Date?  // не nil только у running

    /// Момент, в который очередь передала задачу обработчику в ТЕКУЩЕЙ попытке.
    /// nil — не передавала: задача либо ждёт, либо взята `claimNext` и ещё не запущена.
    /// Живёт одну попытку, снимается при каждом возврате в `pending` и при каждом
    /// терминальном исходе (инвариант 34).
    public let attemptStartedAt: Date?

    public let lastError: String?
    public let createdAt: Date
    public let updatedAt: Date

    public init(
        id: UUID,
        type: JobType,
        payload: JobPayload,
        status: JobStatus,
        priority: Int,
        attempts: Int,
        maxAttempts: Int,
        runAfter: Date,
        conditions: JobConditions,
        dedupKey: String?,
        leaseExpiresAt: Date?,
        attemptStartedAt: Date?,
        lastError: String?,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.status = status
        self.priority = priority
        self.attempts = attempts
        self.maxAttempts = maxAttempts
        self.runAfter = runAfter
        self.conditions = conditions
        self.dedupKey = dedupKey
        self.leaseExpiresAt = leaseExpiresAt
        self.attemptStartedAt = attemptStartedAt
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct JobSubmission: Codable, Equatable, Sendable {
    public let payload: JobPayload
    public let priority: Int
    public let maxAttempts: Int
    public let runAfter: Date
    public let conditions: JobConditions
    public let dedupKey: String?

    public init(
        payload: JobPayload,
        priority: Int,
        maxAttempts: Int,
        runAfter: Date,
        conditions: JobConditions,
        dedupKey: String?
    ) {
        self.payload = payload
        self.priority = priority
        self.maxAttempts = maxAttempts
        self.runAfter = runAfter
        self.conditions = conditions
        self.dedupKey = dedupKey
    }
}

// MARK: - §2. Обработчики и очередь

public enum JobOutcome: Equatable, Sendable {
    case success
    /// Явная задержка от обработчика, в секундах.
    ///
    /// Контракт пишет здесь `TimeInterval`; тип тот же — `TimeInterval` есть
    /// `typealias` к `Double`, — а написание другое, и это НЕ вольность.
    /// Шаг «Символьный граф» разбирает USR: на macOS `TimeInterval` приходит
    /// псевдонимом C/ObjC (`CFTimeInterval`), в базовый набор модулей не входит
    /// и краснит барьер по модулю объявления — прогон CI 140, `DomainCore:
    /// <C/ObjC> — TimeInterval`, по нарушению в каждом из двух пакетов. На Linux
    /// того же прогона нарушений ноль: там это чистый псевдоним Foundation.
    /// В дереве `57a2ca3` `TimeInterval` не стоял в публичной сигнатуре ни разу —
    /// все его вхождения внутренние либо тестовые (свой прогон).
    /// Ровно этот класс называют инвариант 9 C-005 и инвариант 19 C-010:
    /// «`TimeInterval` и `CFTimeInterval` (есть `Double`)» — в разрешённые списки
    /// не входят. Ответа правка не меняет ни на одном входе; контракт не тронут
    /// ни символом. Находка — строка владельцу C-013, отчёт MEE-289.
    case retry(after: Double, error: String)
    case permanentFailure(error: String)             // повторять бессмысленно
}

public protocol JobHandler: Sendable {
    var type: JobType { get }
    func run(_ job: Job,
             progress: @Sendable @escaping (Double) -> Void) async -> JobOutcome
}

public enum JobBlockReason: String, Codable, Sendable {
    case notYetDue
    case waitingForACPower
    case recordingInProgress
    case thermalPressure
    case concurrencyLimit
    case noHandler
    case profileNotReady        // добавлено в v2; §1.1
}

public enum JobEvent: Equatable, Sendable {
    case submitted(jobId: UUID, type: JobType)
    case started(jobId: UUID, type: JobType)
    case progressed(jobId: UUID, fraction: Double)
    case succeeded(jobId: UUID, type: JobType)
    case failed(jobId: UUID, type: JobType, error: String, willRetry: Bool)
    case cancelled(jobId: UUID, type: JobType)
    case blocked(jobId: UUID, type: JobType, reason: JobBlockReason)
}

public enum JobQueueError: Error, Codable, Equatable, Sendable {
    case unknownJob(UUID)
    case invalidPriority(Int)
    case handlerAlreadyRegistered(JobType)
}

public protocol JobQueue: Sendable {
    func register(handler: JobHandler) async throws
    func submit(_ submission: JobSubmission) async throws -> UUID
    func cancel(jobId: UUID) async throws
    func job(id: UUID) async throws -> Job?
    func jobs(status: JobStatus) async throws -> [Job]
    func start() async
    func stop() async
    func events() -> AsyncStream<JobEvent>
}
