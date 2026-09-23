//  MEE-320: `DomainTestKit.InMemoryJobRepository` — C-013 §«Фейк для тестов», К84 (часть).
//  `ManualClock` и `FakeJobQueue`/`FakeJobHandler` (тоже К84) — в `ManualClockTests.swift` и
//  уже существующем `FakeJobQueueTests.swift` соответственно.
//
//  К84 дословно (часть про `InMemoryJobRepository`): «исполняет `excluding` при любом
//  размере множества, называет объявленную нечитаемой строку в `JobListing.unreadable`
//  вместо отказа, бросает `dataCorrupted` на всех прочих читающих методах до перевода
//  строки в `failed`, хранит `attemptStartedAt` и снимает его в `nil` при `claimNext`,
//  позволяет вставить строку `running` с заданной отметкой и без неё, считает вызовы
//  `claimNext` и `failUnreadable`».
//
//  ГРАНИЦА НАЗВАНА: держимые правила суть УСТРОЙСТВО фейка, а не проверка самой очереди —
//  очереди (`JobQueue`) в дереве ещё нет, её тесты (способ И, К50—К83) придут с её реализацией.

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryJobRepositoryTests: XCTestCase {
}

// MARK: - excluding, порядок claimNext, снятие attemptStartedAt

extension InMemoryJobRepositoryTests {

    /// `excluding` исключает кандидата при любом размере множества — пустом, из одного и
    /// из всех кандидатов сразу.
    func test_mee320_claimNext_excludingWorksAtAnySize() async throws {
        let repo = InMemoryJobRepository()
        let low = job(priority: 10)
        let high = job(priority: 20)
        try await repo.insert(low)
        try await repo.insert(high)

        let withEmptySet = try await repo.claimNext(
            types: JobType.allCases, excluding: [], now: epoch, leaseSeconds: 60
        )
        XCTAssertEqual(withEmptySet?.id, high.id, "вектор непустоты: пустое множество не исключает никого")

        try await repo.update(high) // вернуть high в pending для следующего вектора
        let excludingHigh = try await repo.claimNext(
            types: JobType.allCases, excluding: [high.id], now: epoch, leaseSeconds: 60
        )
        XCTAssertEqual(excludingHigh?.id, low.id, "одно исключённое — берётся следующий")

        try await repo.update(low)
        let excludingBoth = try await repo.claimNext(
            types: JobType.allCases, excluding: [low.id, high.id], now: epoch, leaseSeconds: 60
        )
        XCTAssertNil(excludingBoth, "исключены все — кандидатов нет")
    }

    /// Инвариант 3 C-013, ступень «`runAfter`»: тот же приоритет — раньше по `runAfter`.
    func test_mee320_claimNext_ordersByPriorityThenRunAfter() async throws {
        let repo = InMemoryJobRepository()
        let laterRunAfter = job(priority: 10, runAfter: epoch.addingTimeInterval(10), createdAt: epoch)
        let earlierRunAfter = job(priority: 10, runAfter: epoch, createdAt: epoch)
        try await repo.insert(laterRunAfter)
        try await repo.insert(earlierRunAfter)

        let picked = try await repo.claimNext(
            types: JobType.allCases, excluding: [], now: epoch.addingTimeInterval(100), leaseSeconds: 60
        )
        XCTAssertEqual(picked?.id, earlierRunAfter.id, "тот же приоритет — раньше по runAfter")
    }

    /// Инвариант 3 C-013, ступень «`createdAt`» (возврат по приёмке MEE-320 — эта ступень
    /// не проверялась вовсе): при равном `priority` и `runAfter` берётся более ранняя
    /// `createdAt`.
    func test_mee320_claimNext_ordersByCreatedAtWhenPriorityAndRunAfterTie() async throws {
        let repo = InMemoryJobRepository()
        let laterCreated = job(priority: 5, runAfter: epoch, createdAt: epoch.addingTimeInterval(10))
        let earlierCreated = job(priority: 5, runAfter: epoch, createdAt: epoch)
        try await repo.insert(laterCreated)
        try await repo.insert(earlierCreated)

        let picked = try await repo.claimNext(
            types: JobType.allCases, excluding: [], now: epoch.addingTimeInterval(100), leaseSeconds: 60
        )
        XCTAssertEqual(picked?.id, earlierCreated.id, "тот же priority и runAfter — раньше по createdAt")
    }

    /// Инвариант 3 C-013, последняя ступень «`id`» (возврат по приёмке MEE-320 — эта ступень
    /// не проверялась вовсе): при равенстве всех трёх прежних ключей побеждает меньший
    /// `UUID.uuidString` лексикографически.
    func test_mee320_claimNext_ordersByIdWhenEverythingElseTies() async throws {
        let repo = InMemoryJobRepository()
        let smallerId = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let largerId = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001"))
        let tiedRunAfter = epoch
        let tiedCreatedAt = epoch
        let withSmallerId = job(
            id: smallerId, priority: 5, runAfter: tiedRunAfter, createdAt: tiedCreatedAt
        )
        let withLargerId = job(
            id: largerId, priority: 5, runAfter: tiedRunAfter, createdAt: tiedCreatedAt
        )
        try await repo.insert(withLargerId)
        try await repo.insert(withSmallerId)

        let picked = try await repo.claimNext(
            types: JobType.allCases, excluding: [], now: epoch.addingTimeInterval(100), leaseSeconds: 60
        )
        XCTAssertEqual(picked?.id, smallerId, "priority, runAfter, createdAt равны — меньший id лексикографически")
    }

    /// Инвариант 26 C-010: `claimNext`, взяв кандидата, снимает `attemptStartedAt` в `nil`
    /// той же транзакцией, что ставит `running` и лизинг.
    func test_mee320_claimNext_clearsAttemptStartedAtAndSetsLease() async throws {
        let repo = InMemoryJobRepository()
        let source = job(priority: 0, attemptStartedAt: epoch)
        try await repo.insert(source)

        let claimed = try await repo.claimNext(
            types: JobType.allCases, excluding: [], now: epoch, leaseSeconds: 90
        )
        let picked = try XCTUnwrap(claimed)
        XCTAssertEqual(picked.status, .running)
        XCTAssertNil(picked.attemptStartedAt, "снято в nil, даже если было задано у исходной строки")
        XCTAssertEqual(picked.leaseExpiresAt, epoch.addingTimeInterval(90))
    }

    /// Позволяет вставить строку `running` с заданной отметкой и без неё — прямо через
    /// `insert(_:)`, других средств контракт не требует.
    func test_mee320_insert_acceptsRunningRowWithAndWithoutAttemptStartedAt() async throws {
        let repo = InMemoryJobRepository()
        let withMark = job(status: .running, attemptStartedAt: epoch)
        let withoutMark = job(status: .running, attemptStartedAt: nil)
        try await repo.insert(withMark)
        try await repo.insert(withoutMark)

        let stored = repo.storedJobs
        XCTAssertEqual(stored.first { $0.id == withMark.id }?.attemptStartedAt, epoch)
        XCTAssertEqual(stored.first { $0.id == withoutMark.id }?.attemptStartedAt, nil)
    }
}

// MARK: - Строка, объявленная нечитаемой

extension InMemoryJobRepositoryTests {

    /// `markUnreadable` бросает заданную ошибку на `job(id:)`, `activeJob(dedupKey:)` и
    /// `claimNext`, пока `failUnreadable` не переведёт строку в `failed`; `jobs(status:)`
    /// не бросает никогда — называет строку в `unreadable` (проверено отдельным вектором).
    func test_mee320_markUnreadable_throwsOnReadingMethodsUntilFailUnreadable() async throws {
        let repo = InMemoryJobRepository()
        let bad = job(priority: 0, dedupKey: "k")
        try await repo.insert(bad)
        let corrupted = StorageError.dataCorrupted(entity: "Job", id: bad.id.uuidString, message: "битый payload")
        repo.markUnreadable(jobId: bad.id, error: corrupted)

        await assertThrowsCorrupted(corrupted) { try await repo.job(id: bad.id) }
        await assertThrowsCorrupted(corrupted) { try await repo.activeJob(dedupKey: "k") }
        await assertThrowsCorrupted(corrupted) {
            try await repo.claimNext(types: JobType.allCases, excluding: [], now: epoch, leaseSeconds: 60)
        }

        let type = try await repo.failUnreadable(jobId: bad.id, message: "унесено ремонтом", now: epoch)
        XCTAssertEqual(type, .transcode, "переведена, тип назван")

        // После ремонта строка всё ещё не собирается: job(id:) по-прежнему отказывает
        // (шапка файла, дословная цитата «Фейк для тестов»).
        await assertThrowsCorrupted(corrupted) { try await repo.job(id: bad.id) }
        // claimNext её больше не видит — статус terminal, не pending.
        let none = try await repo.claimNext(
            types: JobType.allCases, excluding: [], now: epoch, leaseSeconds: 60
        )
        XCTAssertNil(none, "статус failed — не кандидат")
    }

    /// `jobs(status:)` не бросает вовсе: нечитаемая строка называется в `unreadable`,
    /// а не в `jobs`; после ремонта остаётся там же, среди `.failed` (шапка файла).
    func test_mee320_jobsStatus_namesUnreadableRowInsteadOfThrowing() async throws {
        let repo = InMemoryJobRepository()
        let good = job(priority: 0)
        let bad = job(priority: 0)
        try await repo.insert(good)
        try await repo.insert(bad)
        let corrupted = StorageError.dataCorrupted(entity: "Job", id: bad.id.uuidString, message: "не читается")
        repo.markUnreadable(jobId: bad.id, error: corrupted)

        let pending = try await repo.jobs(status: .pending)
        XCTAssertEqual(pending.jobs.map(\.id), [good.id], "читаемая — в jobs")
        XCTAssertEqual(pending.unreadable, [UnreadableJobRow(id: bad.id, message: "не читается")])

        _ = try await repo.failUnreadable(jobId: bad.id, message: "не читается", now: epoch)
        let failed = try await repo.jobs(status: .failed)
        XCTAssertEqual(failed.jobs, [], "failed-задачу собрать по-прежнему нечем")
        XCTAssertEqual(
            failed.unreadable, [UnreadableJobRow(id: bad.id, message: "не читается")],
            "и после ремонта названа, а не пропала"
        )
    }

    private func assertThrowsCorrupted(
        _ expected: StorageError, _ body: () async throws -> Job?
    ) async {
        do {
            _ = try await body()
            XCTFail("ожидался \(expected)")
        } catch let error as StorageError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("неожиданный тип ошибки: \(error)")
        }
    }
}

// MARK: - failUnreadable: идемпотентность, терминальные строки, счётчики

extension InMemoryJobRepositoryTests {

    /// Инварианты 23/25 C-013: `failUnreadable` не трогает `succeeded`/`cancelled`,
    /// идемпотентна и не действует на неизвестный идентификатор — всё без эффекта, не отказ.
    func test_mee320_failUnreadable_skipsTerminalAndUnknownIdsWithoutEffect() async throws {
        let repo = InMemoryJobRepository()
        let succeeded = job(status: .succeeded)
        try await repo.insert(succeeded)

        let onTerminal = try await repo.failUnreadable(jobId: succeeded.id, message: "поздно", now: epoch)
        XCTAssertNil(onTerminal, "терминальная строка не тронута")
        let stillSucceeded = try await repo.job(id: succeeded.id)
        XCTAssertEqual(stillSucceeded?.status, .succeeded)

        let onUnknown = try await repo.failUnreadable(jobId: UUID(), message: "нет такой", now: epoch)
        XCTAssertNil(onUnknown, "неизвестный id — без эффекта")

        let pendingJob = job(status: .pending)
        try await repo.insert(pendingJob)
        let first = try await repo.failUnreadable(jobId: pendingJob.id, message: "m1", now: epoch)
        let second = try await repo.failUnreadable(jobId: pendingJob.id, message: "m2", now: epoch)
        XCTAssertEqual(first, .transcode)
        XCTAssertNil(second, "повторный вызов на уже terminal — без эффекта, не отказ")
        let afterSecond = try await repo.job(id: pendingJob.id)
        XCTAssertEqual(afterSecond?.lastError, "m1", "второй вызов не переписал lastError")
    }

    /// К84: считает всякий вызов `claimNext`/`failUnreadable`, включая давшие `nil`.
    func test_mee320_countsEveryClaimNextAndFailUnreadableCall() async throws {
        let repo = InMemoryJobRepository()
        XCTAssertEqual(repo.claimNextCallCount, 0, "вектор непустоты: до вызовов ноль")
        XCTAssertEqual(repo.failUnreadableCallCount, 0)

        _ = try await repo.claimNext(types: JobType.allCases, excluding: [], now: epoch, leaseSeconds: 60)
        _ = try await repo.claimNext(types: JobType.allCases, excluding: [], now: epoch, leaseSeconds: 60)
        XCTAssertEqual(repo.claimNextCallCount, 2, "оба вызова посчитаны, хотя оба дали nil")

        _ = try await repo.failUnreadable(jobId: UUID(), message: "m", now: epoch)
        XCTAssertEqual(repo.failUnreadableCallCount, 1, "посчитан и вызов без эффекта")
    }

    /// Инварианты 10/11 C-013: истёкший лизинг — та же развилка, что у `start()`: с
    /// отметкой — `attempts + 1`, без отметки — прежний.
    func test_mee320_reclaimExpiredLeases_branchesOnAttemptStartedAt() async throws {
        let repo = InMemoryJobRepository()
        let started = job(
            status: .running, attempts: 0, maxAttempts: 5,
            leaseExpiresAt: epoch.addingTimeInterval(-1), attemptStartedAt: epoch.addingTimeInterval(-10)
        )
        let notStarted = job(
            status: .running, attempts: 1, maxAttempts: 5,
            leaseExpiresAt: epoch.addingTimeInterval(-1), attemptStartedAt: nil
        )
        try await repo.insert(started)
        try await repo.insert(notStarted)

        let reclaimed = try await repo.reclaimExpiredLeases(now: epoch)
        let byId = Dictionary(uniqueKeysWithValues: reclaimed.map { ($0.id, $0) })

        XCTAssertEqual(byId[started.id]?.attempts, 1, "с отметкой — attempts + 1")
        XCTAssertEqual(byId[started.id]?.lastError, "interrupted")
        XCTAssertEqual(byId[started.id]?.status, .pending)
        // Формула §5 C-013 (возврат по приёмке MEE-320 — runAfter не проверялся числом):
        // min(30 * 2^(attempts_new - 1), 1800) = min(30 * 2^0, 1800) = 30 секунд от `now`.
        XCTAssertEqual(byId[started.id]?.runAfter, epoch.addingTimeInterval(30), "задержка §5: 30 * 2^(1-1)")

        XCTAssertEqual(byId[notStarted.id]?.attempts, 1, "без отметки — прежний")
        XCTAssertEqual(byId[notStarted.id]?.status, .pending)
        XCTAssertEqual(byId[notStarted.id]?.runAfter, notStarted.runAfter, "runAfter не тронут — работы не было")
    }

    /// Инвариант 10 C-013 (через инвариант 11): исчерпаны попытки — переход в `failed`,
    /// а не в `pending` (возврат по приёмке MEE-320 — эта ветка не проверялась).
    func test_mee320_reclaimExpiredLeases_transitionsToFailedWhenAttemptsExhausted() async throws {
        let repo = InMemoryJobRepository()
        let exhausted = job(
            status: .running, attempts: 2, maxAttempts: 3,
            leaseExpiresAt: epoch.addingTimeInterval(-1), attemptStartedAt: epoch.addingTimeInterval(-10)
        )
        try await repo.insert(exhausted)

        let reclaimed = try await repo.reclaimExpiredLeases(now: epoch)

        let after = try XCTUnwrap(reclaimed.first)
        XCTAssertEqual(after.attempts, 3, "attempts_new = 2 + 1 = 3 = maxAttempts")
        XCTAssertEqual(after.status, .failed, "attempts_new >= maxAttempts — failed, не pending")
        XCTAssertEqual(after.lastError, "interrupted")
        XCTAssertNil(after.leaseExpiresAt)
        XCTAssertNil(after.attemptStartedAt)
    }

    /// К84: `reclaimExpiredLeases` на нечитаемой строке бросает заданную ошибку — ровно как
    /// `claimNext` (возврат по приёмке MEE-320 — этот метод в векторах нечитаемости
    /// отсутствовал).
    func test_mee320_reclaimExpiredLeases_throwsOnUnreadableRow() async throws {
        let repo = InMemoryJobRepository()
        let stale = job(
            status: .running, leaseExpiresAt: epoch.addingTimeInterval(-1), attemptStartedAt: epoch
        )
        try await repo.insert(stale)
        let corrupted = StorageError.dataCorrupted(entity: "Job", id: stale.id.uuidString, message: "лизинг битый")
        repo.markUnreadable(jobId: stale.id, error: corrupted)

        do {
            _ = try await repo.reclaimExpiredLeases(now: epoch)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            XCTAssertEqual(error, corrupted)
        }
    }
}

// MARK: - Оснастка

extension InMemoryJobRepositoryTests {

    var epoch: Date { Date(timeIntervalSince1970: 1_000_000) }

    private func job(
        id: UUID = UUID(),
        priority: Int = 0,
        status: JobStatus = .pending,
        attempts: Int = 0,
        maxAttempts: Int = 3,
        runAfter: Date = Date(timeIntervalSince1970: 1_000_000),
        dedupKey: String? = nil,
        leaseExpiresAt: Date? = nil,
        attemptStartedAt: Date? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> Job {
        Job(
            id: id, type: .transcode, payload: .transcode(recordingId: UUID()), status: status,
            priority: priority, attempts: attempts, maxAttempts: maxAttempts, runAfter: runAfter,
            conditions: JobConditions(
                requiresACPower: false, forbidWhileRecording: false,
                maxThermalPressure: .serious, requiresProfileReady: nil
            ),
            dedupKey: dedupKey, leaseExpiresAt: leaseExpiresAt, attemptStartedAt: attemptStartedAt,
            lastError: nil, createdAt: createdAt, updatedAt: createdAt
        )
    }
}
