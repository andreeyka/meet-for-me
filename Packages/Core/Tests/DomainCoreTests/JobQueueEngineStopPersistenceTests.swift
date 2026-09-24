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
    ///
    /// Возврат РП по MEE-350: «кандидат, взятый пересмотром и не переданный обработчику» —
    /// прежде строка, вставленная НАПРЯМУЮ (`makeRunningRow`), изображавшая это состояние
    /// подделкой; ничто не проверяло, что `runRevisitPass` и `stop()` вправду producят и
    /// перехватывают его сами. Здесь оно настоящее: `StubModelCatalogPort.pauseNextCall(for:)`
    /// подвешивает `firstBlockingReason` РОВНО в точке между тем, как `claimNext` уже пометил
    /// строку `running` (это делает сам фейк репозитория), и тем, как пересмотр решил её
    /// судьбу — актор в этот момент приостановлен на настоящем `await`, а не занят, и потому
    /// свободен обработать `stop()`, вызванный из теста конкурентно. Таймингов и `sleep` нет:
    /// подвес и снятие управляются явно, гонки не может быть по построению.
    func test_k70_stopWaitsForExecutingAndReturnsUnstartedCandidate() async throws {
        let rig = JobQueueTestRig()
        let executingHandler = FakeJobHandler(type: .transcode)
        executingHandler.workLong(seconds: 0.3)
        try await rig.queue.register(handler: executingHandler)
        let strayHandler = FakeJobHandler(type: .attribute)
        try await rig.queue.register(handler: strayHandler)

        let executingId = try await rig.queue.submit(makeSubmission(priority: 20))
        let strayId = try await rig.queue.submit(makeSubmission(
            payload: .attribute(transcriptId: UUID(), meetingId: nil),
            priority: 10, requiresProfileReady: "p"
        ))
        rig.catalog.setMissingModels([], for: "p")   // «выполнено» — иначе блокировка иная, не эта
        rig.catalog.pauseNextCall(for: "p")

        // Один `start()`: в одном пересмотре сперва берёт `executingId` (выше приоритетом,
        // без условий — сразу исполняется), затем `strayId` — и подвисает на его условии.
        let startTask = Task { await rig.queue.start() }

        // Ждём НАБЛЮДАЕМОГО факта — `claimNext` уже пометил `strayId` running — а не
        // фиксированную паузу: опрос читает фейк репозитория напрямую, актора не трогает.
        // Ограничение попыток — а не бесконечный цикл: если пересмотр когда-нибудь перестанет
        // доходить до `strayId` вообще, тест обязан упасть с внятным `XCTFail`, а не зависнуть
        // тем же классом проблемы, что уже вызывал зависания CI (`AsyncStream` без `finish()`).
        var attemptsLeft = 10_000
        while try await rig.repository.job(id: strayId)?.status != .running {
            attemptsLeft -= 1
            guard attemptsLeft > 0 else {
                return XCTFail("strayId не дошёл до running — пересмотр не добрался до claimNext по нему")
            }
            await Task.yield()
        }
        let claimedStray = try await rig.repository.job(id: strayId)
        XCTAssertNil(claimedStray?.attemptStartedAt, "взят claimNext, но обработчику ещё не передан")

        await rig.queue.stop()   // конкурентно с зависшим на condition-check пересмотром

        // Возврат РП по MEE-350: проверка статуса СРАЗУ после `stop()`, ДО снятия подвеса —
        // иначе кандидата мог вернуть в pending сам возобновившийся пересмотр (его собственный
        // `guard isRunning else { ... }`, JobQueueEngineReview.swift), а не `stop()`, и тест
        // это не различил бы.
        let strayRightAfterStop = try await rig.repository.job(id: strayId)
        XCTAssertEqual(
            strayRightAfterStop?.status, .pending, "это stop() вернул кандидата, а не возобновившийся пересмотр"
        )

        rig.catalog.releaseGatedCall()   // отпускаем подвес уже ПОСЛЕ stop() — не раньше
        await startTask.value            // дожидаемся, чтобы пересмотр точно закончился

        let stray = try await rig.repository.job(id: strayId)
        XCTAssertEqual(stray?.status, .pending)
        XCTAssertEqual(stray?.attempts, 0)
        XCTAssertNil(stray?.leaseExpiresAt)
        XCTAssertNil(stray?.attemptStartedAt)
        XCTAssertEqual(strayHandler.runCallCount, 0, "stop() не начал новых задач — обработчик не звался вовсе")

        let finishedExecuting = try await rig.repository.job(id: executingId)
        XCTAssertNotEqual(finishedExecuting?.status, .running, "stop() вернулся после завершения исполняемой")

        let anyRunning = try await rig.repository.jobs(status: .running)
        XCTAssertTrue(anyRunning.jobs.isEmpty, "после stop() строк running не осталось ни одной")

        await rig.queue.stop()   // повторный — без эффекта, не бросает
    }

    /// К71: состояние очереди целиком выводится из таблицы `jobs` — новый экземпляр очереди
    /// поверх того же репозитория восстанавливает те же `pending`-задачи (с точностью до
    /// развилки инварианта 10).
    ///
    /// Усиление по возврату РП (MEE-350): пять строк — по числу случаев `JobStatus` — вместо
    /// прежних трёх (`failed`/`cancelled` не были названы вовсе, а без них «целиком выводится
    /// из таблицы» проверяет только часть случаев). Плюс — `rig.queue.start()` до всякой
    /// прямой правки репозитория: первый экземпляр очереди — не пустая заглушка, которую
    /// никогда не запускали, а прошедший хотя бы один настоящий пересмотр, как в реальном
    /// перезапуске приложения (иначе строка гонится с состоянием, которое сам первый экземпляр
    /// никогда не видел живым).
    func test_k71_stateIsDerivedEntirelyFromTheJobsTable() async throws {
        let rig = JobQueueTestRig()
        await rig.queue.start()   // первый экземпляр — реально запущенный, а не пустая заглушка
        let now = rig.clock.now()

        let pending = makeRunningRow(attempts: 0, maxAttempts: 3, attemptStartedAt: nil, leaseExpiresAt: nil, now: now)
        try await upsertTerminalOrPendingRow(
            rig, base: pending, status: .pending, priority: 7, dedupKey: "d1", now: now
        )

        let running = makeRunningRow(
            attempts: 1, maxAttempts: 5, attemptStartedAt: now,
            leaseExpiresAt: now.addingTimeInterval(50), now: now
        )
        try await rig.repository.insert(running)

        let succeeded = makeRunningRow(
            attempts: 1, maxAttempts: 3, attemptStartedAt: nil, leaseExpiresAt: nil, now: now
        )
        try await upsertTerminalOrPendingRow(rig, base: succeeded, status: .succeeded, now: now)

        let failed = makeRunningRow(
            attempts: 3, maxAttempts: 3, attemptStartedAt: nil, leaseExpiresAt: nil, lastError: "boom", now: now
        )
        try await upsertTerminalOrPendingRow(rig, base: failed, status: .failed, lastError: "boom", now: now)

        let cancelled = makeRunningRow(
            attempts: 0, maxAttempts: 3, attemptStartedAt: nil, leaseExpiresAt: nil, now: now
        )
        try await upsertTerminalOrPendingRow(rig, base: cancelled, status: .cancelled, now: now)

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

        let failedAfter = try await rig.repository.job(id: failed.id)
        XCTAssertEqual(failedAfter?.status, .failed, "терминальная строка не тронута")
        XCTAssertEqual(failedAfter?.lastError, "boom")

        let cancelledAfter = try await rig.repository.job(id: cancelled.id)
        XCTAssertEqual(cancelledAfter?.status, .cancelled, "терминальная строка не тронута")

        let succeededAfter = try await rig.repository.job(id: succeeded.id)
        XCTAssertEqual(succeededAfter?.status, .succeeded, "терминальная строка не тронута")

        await secondQueue.stop()
    }

    /// Оснастка К71 — вынесена из тела теста, чтобы уложиться в `function_body_length`
    /// (50 строк, возврат РП по MEE-350): пять строк отличались только статусом и парой
    /// полей. `running` через неё не идёт — ей нужны настоящие `attemptStartedAt`/`leaseExpiresAt`,
    /// а не захардкоженный `nil` этого помощника.
    private func upsertTerminalOrPendingRow(
        _ rig: JobQueueTestRig, base: Job, status: JobStatus, priority: Int = 0,
        dedupKey: String? = nil, lastError: String? = nil, now: Date
    ) async throws {
        try await rig.repository.update(Job(
            id: base.id, type: base.type, payload: base.payload, status: status,
            priority: priority, attempts: base.attempts, maxAttempts: base.maxAttempts, runAfter: now,
            conditions: base.conditions, dedupKey: dedupKey, leaseExpiresAt: nil, attemptStartedAt: nil,
            lastError: lastError, createdAt: now, updatedAt: now
        ))
    }
}
