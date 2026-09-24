//  Группа N перечня MEE-189 (остановка и персистентность) — К70, К71. C-013 v8, MEE-350.
//  К72 (инвариант 18, «нет macOS-импортов») — способ Ж, сама сборка `Core (Linux)`;
//  отдельного теста не несёт, названо в отчёте.

import XCTest
import DomainCore
import DomainTestKit

final class JobQueueEngineStopPersistenceTests: XCTestCase {

    /// К70: `stop()` не начинает новых задач, дожидается исполняемой, возвращает в `pending`
    /// кандидата, взятого пересмотром и ещё не переданного обработчику; после возврата
    /// строк `running` не остаётся. Повторный `stop()` — без эффекта.
    func test_k70_stopWaitsForExecutingAndReturnsUnstartedCandidate() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        handler.workLong(seconds: 0.3)
        try await rig.queue.register(handler: handler)

        let executingId = try await rig.queue.submit(makeSubmission(priority: 10))
        await rig.queue.start()
        let executing = try await rig.repository.job(id: executingId)
        XCTAssertEqual(executing?.status, .running, "вектор непустоты: задача правда исполняется")

        // Кандидат, взятый пересмотром и не переданный обработчику, — тем же признаком, что
        // инвариант 12 называет прямо (`attemptStartedAt == nil` в `running`).
        let now = rig.clock.now()
        let strayCandidate = makeRunningRow(
            attempts: 0, maxAttempts: 3, attemptStartedAt: nil,
            leaseExpiresAt: now.addingTimeInterval(100), now: now
        )
        try await rig.repository.insert(strayCandidate)

        await rig.queue.stop()

        let stray = try await rig.repository.job(id: strayCandidate.id)
        XCTAssertEqual(stray?.status, .pending)
        XCTAssertEqual(stray?.attempts, 0)
        XCTAssertNil(stray?.leaseExpiresAt)
        XCTAssertNil(stray?.attemptStartedAt)

        let finishedExecuting = try await rig.repository.job(id: executingId)
        XCTAssertNotEqual(finishedExecuting?.status, .running, "stop() вернулся после завершения исполняемой")

        let anyRunning = try await rig.repository.jobs(status: .running)
        XCTAssertTrue(anyRunning.jobs.isEmpty, "после stop() строк running не осталось ни одной")

        await rig.queue.stop()   // повторный — без эффекта, не бросает
    }

    /// К71: состояние очереди целиком выводится из таблицы `jobs` — новый экземпляр очереди
    /// поверх того же репозитория восстанавливает те же `pending`-задачи (с точностью до
    /// развилки инварианта 10).
    func test_k71_stateIsDerivedEntirelyFromTheJobsTable() async throws {
        let rig = JobQueueTestRig()
        let now = rig.clock.now()

        let pending = makeRunningRow(attempts: 0, maxAttempts: 3, attemptStartedAt: nil, leaseExpiresAt: nil, now: now)
        try await rig.repository.update(Job(
            id: pending.id, type: pending.type, payload: pending.payload, status: .pending,
            priority: 7, attempts: 0, maxAttempts: 3, runAfter: now, conditions: pending.conditions,
            dedupKey: "d1", leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil,
            createdAt: now, updatedAt: now
        ))
        let running = makeRunningRow(
            attempts: 1, maxAttempts: 5, attemptStartedAt: now,
            leaseExpiresAt: now.addingTimeInterval(50), now: now
        )
        try await rig.repository.insert(running)
        let succeeded = makeRunningRow(
            attempts: 1, maxAttempts: 3, attemptStartedAt: nil, leaseExpiresAt: nil, now: now
        )
        try await rig.repository.update(Job(
            id: succeeded.id, type: succeeded.type, payload: succeeded.payload, status: .succeeded,
            priority: 0, attempts: 1, maxAttempts: 3, runAfter: now, conditions: succeeded.conditions,
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil,
            createdAt: now, updatedAt: now
        ))

        // Новая очередь поверх ТОГО ЖЕ репозитория — прежний экземпляр ничего не хранил
        // в памяти, что понадобилось бы восстановить.
        let secondQueue = JobQueueEngine(
            repository: rig.repository, modelCatalog: rig.catalog, powerPort: rig.power,
            clock: { rig.clock.now() }
        )
        await secondQueue.start()

        let pendingAfter = try await rig.repository.job(id: pending.id)
        XCTAssertEqual(pendingAfter?.status, .pending)
        XCTAssertEqual(pendingAfter?.priority, 7)
        XCTAssertEqual(pendingAfter?.dedupKey, "d1")

        let runningAfter = try await rig.repository.job(id: running.id)
        XCTAssertEqual(runningAfter?.status, .pending, "running восстановлена по инварианту 10 (К61)")
        XCTAssertEqual(runningAfter?.attempts, 2, "была передана обработчику — attempts + 1")

        let succeededAfter = try await rig.repository.job(id: succeeded.id)
        XCTAssertEqual(succeededAfter?.status, .succeeded, "терминальная строка не тронута")

        await secondQueue.stop()
    }
}
