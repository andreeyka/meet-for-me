//  InMemoryJobRepository — реализация `JobRepository` поверх словаря, C-013 v7
//  §«Фейк для тестов»: «с теми же правилами `claimNext` и `reclaimExpiredLeases`, что у
//  настоящей таблицы. Позволяет протестировать саму очередь без GRDB и на Linux».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  МЕХАНИКА «ОБЪЯВИТЬ СТРОКУ НЕЧИТАЕМОЙ» — ДОСЛОВНО ПО «Добавлено в v2»/«v3» §«Фейк для
//  тестов»: «`InMemoryJobRepository` умеет по команде теста объявить заданный `id`
//  нечитаемым — бросать `StorageError.dataCorrupted` с заданными `entity`, `id` и `message`
//  на всех бросающих читающих методах (с v3 это все, кроме `jobs(status:)`), пока
//  `failUnreadable` не переведёт строку в `failed`; после этого строка ведёт себя как
//  обычная `failed`-задача, которую невозможно собрать: в `JobListing.jobs` её нет, в
//  `JobListing.unreadable` она названа, и `job(id:)` на ней по-прежнему отказывает.»
//  Отсюда устройство: `unreadable[id]` — флаг теста, НЕЗАВИСИМЫЙ от статуса строки и НЕ
//  снимаемый `failUnreadable` — реальный `payload_json` тем же вызовом не чинится, только
//  меняются служебные поля строки (инвариант 23/25 C-013).
//
//  `claimNext`/`reclaimExpiredLeases`/`activeJob(dedupKey:)` бросают заданную ошибку, когда
//  строка, отвечающая их критерию отбора, помечена нечитаемой, — ровно так, как настоящий
//  порт бросил бы её, наткнувшись на неразбираемый `payload_json` при попытке собрать
//  `Job`. `insert`/`update` не разбирают `payload_json` (они его ПИШУТ) и `dataCorrupted`
//  не бросают никогда — по «Поведению» C-010 и явному исключению у `failUnreadable`.
//
//  СЧЁТЧИКИ `claimNext`/`failUnreadable` (К84) считают ВСЯКИЙ вызов, включая давшие `nil`
//  и давшие отказ, — тем же классом, что `FakeJobHandler.runCallCount` у соседнего фейка:
//  число исполнений/попыток, а не число успешных исходов.
//
//  ПОРЯДОК ВЫБОРА `claimNext` — инвариант 3 C-013 дословно: больше `priority`; при равном —
//  меньше `runAfter`; при равенстве обоих — меньше `createdAt`; при равенстве всех трёх —
//  меньше `id` в лексикографическом сравнении `UUID.uuidString`.
//
//  IR-111 ([MEE-323]) закрыт изданием C-013 v7 ([MEE-21]): `reclaimExpiredLeases`
//  ОТДАЁТ строки как есть — не ветвится по `attemptStartedAt`, не пересчитывает
//  `attempts`, не трогает `status` и лизинг. Решение по инвариантам 10/11 (что
//  делать с истёкшим лизингом — `attempts + 1`, формула отката §5, переход в
//  `failed` при исчерпании) принимает очередь, которая читает возврат метода и
//  пишет решение через `update(_ job:)` — «Чем проверяется» C-013 v7, строки
//  585/586 (`reclaimExpiredLeases` отдаёт строки как есть / истёкший лизинг
//  ветвится в тесте очереди, а не репозитория). Прежняя пометка `СТРОКА:
//  IR-111` брала временное чтение (б) — ветвление внутри репозитория; снята
//  вместе с рассуждением, вопрос закрыт архитектором не в мою пользу.
//
//  СТРОКА (мелкое, приёмка MEE-320): `jobs.dedup_key` уникален среди `pending`/`running`
//  (C-010 инвариант 6, половина `jobs`) — этот фейк её НЕ ДЕРЖИТ: `insert`/`update` не
//  сверяют `dedupKey` ни с чем. Держать её значило бы дать `insert` право отказывать
//  (протокол сегодня не бросает `constraintViolation` ни на одном методе `JobRepository` —
//  ни разу не понадобилось до этой строки), а деталь неполноты дешевле развилки: называю
//  строкой, а не решаю за контракт молча. Если способ И потребует критерий на это —
//  довесок к `insert`, не новый метод.
//
//  `@unchecked Sendable` с замком, а не актор: `JobRepository` объявлен `: Sendable`.

import Foundation
import DomainCore

/// Фейк хранилища задач. Всё поведение задаёт тест.
public final class InMemoryJobRepository: JobRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "JobRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var jobsById: [UUID: Job] = [:]
    private var order: [UUID] = []
    /// Строки, объявленные тестом нечитаемыми: id → ошибка, которую бросают читающие методы.
    /// Флаг НЕ снимается `failUnreadable` (шапка файла).
    private var unreadable: [UUID: StorageError] = [:]
    private var claimNextCalls = 0
    private var failUnreadableCalls = 0

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

    /// Объявить строку нечитаемой: команда теста по «Фейк для тестов» C-013, «Добавлено в
    /// v2». `error` — обычно `StorageError.dataCorrupted(entity: "Job", id:
    /// jobId.uuidString, message:)`, но тест волен передать и другой случай (в частности,
    /// `entity != "Job"` или нечитаемый `id` — вход, которым проверяется исход «ремонт
    /// невозможен», §6 п. 4).
    public func markUnreadable(jobId: UUID, error: StorageError) {
        locked { unreadable[jobId] = error }
    }

    /// Снять пометку теста (не часть контракта — симметрична `clearFailure` соседних
    /// фейков, для тестов, которым нужно вернуть строку в читаемое состояние явно).
    public func clearUnreadable(jobId: UUID) {
        locked { unreadable[jobId] = nil }
    }

    /// Число вызовов `claimNext` — считает всякий вызов, включая давшие `nil` и отказ.
    public var claimNextCallCount: Int { locked { claimNextCalls } }

    /// Число вызовов `failUnreadable` — тем же правилом.
    public var failUnreadableCallCount: Int { locked { failUnreadableCalls } }

    /// Всё, что лежит в хранилище, в порядке появления — включая нечитаемые строки.
    public var storedJobs: [Job] {
        locked { order.compactMap { jobsById[$0] } }
    }

    // MARK: - JobRepository: запись и точечное чтение

    public func insert(_ job: Job) async throws {
        log.record(port: Self.portName, method: "insert(_:)", arguments: [job.id.uuidString])
        locked {
            if jobsById[job.id] == nil {
                order.append(job.id)
            }
            jobsById[job.id] = job
        }
    }

    public func update(_ job: Job) async throws {
        log.record(port: Self.portName, method: "update(_:)", arguments: [job.id.uuidString])
        locked {
            if jobsById[job.id] == nil {
                order.append(job.id)
            }
            jobsById[job.id] = job
        }
    }

    public func job(id: UUID) async throws -> Job? {
        log.record(port: Self.portName, method: "job(id:)", arguments: [id.uuidString])
        if let error = locked({ unreadable[id] }) {
            throw error
        }
        return locked { jobsById[id] }
    }

    public func jobs(status: JobStatus) async throws -> JobListing {
        log.record(port: Self.portName, method: "jobs(status:)", arguments: [status.rawValue])
        return locked {
            var readable: [Job] = []
            var badRows: [UnreadableJobRow] = []
            for id in order where jobsById[id]?.status == status {
                if let error = unreadable[id] {
                    badRows.append(UnreadableJobRow(id: id, message: Self.message(of: error)))
                } else if let job = jobsById[id] {
                    readable.append(job)
                }
            }
            return JobListing(jobs: readable, unreadable: badRows)
        }
    }

    public func activeJob(dedupKey: String) async throws -> Job? {
        log.record(port: Self.portName, method: "activeJob(dedupKey:)", arguments: [dedupKey])
        let outcome = locked { () -> ActiveLookup in
            for id in order {
                guard let job = jobsById[id], job.dedupKey == dedupKey,
                      job.status == .pending || job.status == .running else { continue }
                if let error = unreadable[id] {
                    return .unreadable(error)
                }
                return .found(job)
            }
            return .absent
        }
        switch outcome {
        case .found(let job): return job
        case .absent: return nil
        case .unreadable(let error): throw error
        }
    }

    /// Исход поиска активной задачи по `dedupKey` — снят под замком, брошен вне его
    /// (тот же приём, что `TextReplacement` у `InMemoryTranscriptRepository`).
    private enum ActiveLookup {
        case found(Job)
        case absent
        case unreadable(StorageError)
    }

    /// Текст `message`, каким его несёт `error`; для не-`dataCorrupted` — описание целиком
    /// (тест, поместивший сюда другой случай, сам отвечает за то, что читает).
    private static func message(of error: StorageError) -> String {
        if case .dataCorrupted(_, _, let message) = error {
            return message
        }
        return String(describing: error)
    }
}

// MARK: - claimNext, reclaimExpiredLeases, failUnreadable
//
// Вынесено в расширение того же файла намеренно, тем же приёмом, что у
// `InMemoryTranscriptRepository`: тело класса иначе перерастает предел `type_body_length`.

extension InMemoryJobRepository {

    public func claimNext(
        types: [JobType], excluding: Set<UUID>, now: Date, leaseSeconds: Int
    ) async throws -> Job? {
        log.record(
            port: Self.portName, method: "claimNext(types:excluding:now:leaseSeconds:)",
            arguments: [types.map(\.rawValue).joined(separator: ","), String(excluding.count)]
        )
        locked { claimNextCalls += 1 }
        let outcome = locked { () -> ClaimOutcome in
            // СТРОКА: возврат РП по MEE-350 — фильтр `runAfter <= now` здесь ВЕРНУЛ:
            // C-010 инвариант 25 называет `claimNext` фильтрующим «по `status`, `run_after`
            // и `type`» дословно, а C-013 требует от фейка «те же правила `claimNext`, что у
            // настоящей таблицы». Возникающее отсюда противоречие с `JobBlockReason.notYetDue`
            // (строка, не дошедшая по сроку, никогда не доходит до `firstBlockingReason`,
            // делая эту ветвь очереди недостижимой через способ И) — реальное, но снимает его
            // архитектор (открыт IR-121, MEE-356), а не правка фейка задним числом. До ответа
            // IR-121: К56 (i) помечен `XCTSkip`, К73 перестроен на блокировки без `notYetDue`.
            let candidates = order.compactMap { jobsById[$0] }
                .filter {
                    $0.status == .pending && types.contains($0.type)
                        && !excluding.contains($0.id) && $0.runAfter <= now
                }
                .sorted(by: Self.claimOrder)
            guard let picked = candidates.first else { return .empty }
            if let error = unreadable[picked.id] {
                return .unreadable(error)
            }
            let claimed = Job(
                id: picked.id, type: picked.type, payload: picked.payload, status: .running,
                priority: picked.priority, attempts: picked.attempts, maxAttempts: picked.maxAttempts,
                runAfter: picked.runAfter, conditions: picked.conditions, dedupKey: picked.dedupKey,
                leaseExpiresAt: now.addingTimeInterval(Double(leaseSeconds)), attemptStartedAt: nil,
                lastError: picked.lastError, createdAt: picked.createdAt, updatedAt: picked.updatedAt
            )
            jobsById[claimed.id] = claimed
            return .claimed(claimed)
        }
        switch outcome {
        case .claimed(let job): return job
        case .empty: return nil
        case .unreadable(let error): throw error
        }
    }

    /// C-013 v7: отдаёт строки с истёкшим лизингом как есть — не пересчитывает
    /// `attempts`, не трогает `status` и лизинг. Решение по инвариантам 10/11
    /// принимает очередь и пишет его через `update(_ job:)`.
    public func reclaimExpiredLeases(now: Date) async throws -> [Job] {
        log.record(
            port: Self.portName, method: "reclaimExpiredLeases(now:)",
            arguments: [String(now.timeIntervalSince1970)]
        )
        let outcome = locked { () -> ReclaimOutcome in
            let stale = order.compactMap { jobsById[$0] }
                .filter { $0.status == .running && ($0.leaseExpiresAt.map { lease in lease < now } ?? false) }
            for job in stale {
                if let error = unreadable[job.id] {
                    return .unreadable(error)
                }
            }
            return .reclaimed(stale)
        }
        switch outcome {
        case .reclaimed(let jobs): return jobs
        case .unreadable(let error): throw error
        }
    }

    public func failUnreadable(jobId: UUID, message: String, now: Date) async throws -> JobType? {
        log.record(
            port: Self.portName, method: "failUnreadable(jobId:message:now:)",
            arguments: [jobId.uuidString, message]
        )
        locked { failUnreadableCalls += 1 }
        return locked { () -> JobType? in
            guard let job = jobsById[jobId], job.status == .pending || job.status == .running else {
                return nil
            }
            jobsById[jobId] = Job(
                id: job.id, type: job.type, payload: job.payload, status: .failed,
                priority: job.priority, attempts: job.attempts, maxAttempts: job.maxAttempts,
                runAfter: job.runAfter, conditions: job.conditions, dedupKey: job.dedupKey,
                leaseExpiresAt: nil, attemptStartedAt: nil, lastError: message,
                createdAt: job.createdAt, updatedAt: now
            )
            return job.type
        }
    }

    // MARK: - Оснастка

    private enum ClaimOutcome {
        case claimed(Job)
        case empty
        case unreadable(StorageError)
    }

    private enum ReclaimOutcome {
        case reclaimed([Job])
        case unreadable(StorageError)
    }

    /// Инвариант 3 C-013: больше `priority`; при равном — меньше `runAfter`; при равенстве
    /// обоих — меньше `createdAt`; при равенстве всех трёх — меньше `id` лексикографически.
    fileprivate static func claimOrder(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.runAfter != rhs.runAfter { return lhs.runAfter < rhs.runAfter }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
