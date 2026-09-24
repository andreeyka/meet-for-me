//  Группа L перечня MEE-189 (попытки, повторы, лизинг, восстановление) — К59…К63.
//  C-013 v8, MEE-350. К89 (репозиторий, «как есть») — в `InMemoryJobRepositoryTests.swift`,
//  `test_mee320_reclaimExpiredLeases_returnsRowsUnchanged`, тем же входом дословно.

import XCTest
import DomainCore
import DomainTestKit

final class JobQueueEngineRetryLeaseTests: XCTestCase {

    /// К59: `attempts` растёт строго на 1 на каждое ФАКТИЧЕСКОЕ исполнение — три подряд
    /// исхода `.retry`, между ними `ManualClock` двигает время за `runAfter`.
    func test_k59_attemptsGrowsByOnePerActualExecution() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        handler.setOutcome(.retry(after: 10, error: "again"))
        try await rig.queue.register(handler: handler)
        let jobId = try await rig.queue.submit(makeSubmission(maxAttempts: 10))

        for expected in [1, 2, 3] {
            await rig.queue.start()
            await rig.queue.waitUntilIdle()
            let job = try await rig.repository.job(id: jobId)
            XCTAssertEqual(job?.attempts, expected)
            XCTAssertEqual(job?.status, .pending)
            let due = try XCTUnwrap(job?.runAfter)
            rig.clock.set(due.addingTimeInterval(1))
        }
        XCTAssertEqual(handler.runCallCount, 3)
    }

    /// К60, вход 1: задача, доведённая до `attempts == maxAttempts`, — `failed`, обработчик
    /// больше не вызывается, `claimNext` её не возвращает.
    func test_k60_exhaustedAttemptsBecomesFailedAndStaysThatWay() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        handler.setOutcome(.retry(after: 1, error: "retry"))
        try await rig.queue.register(handler: handler)
        let jobId = try await rig.queue.submit(makeSubmission(maxAttempts: 3))

        for _ in 0..<3 {
            await rig.queue.start()
            await rig.queue.waitUntilIdle()
            if let job = try await rig.repository.job(id: jobId), job.status == .pending {
                rig.clock.set(job.runAfter.addingTimeInterval(1))
            }
        }
        let exhausted = try await rig.repository.job(id: jobId)
        XCTAssertEqual(exhausted?.status, .failed)
        XCTAssertEqual(exhausted?.attempts, 3)
        XCTAssertEqual(handler.runCallCount, 3)

        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        XCTAssertEqual(handler.runCallCount, 3, "failed — claimNext её больше не берёт")
    }

    /// К60, вход 2: `.permanentFailure` на первой попытке даёт `failed` немедленно, не
    /// дожидаясь `maxAttempts`.
    func test_k60_permanentFailureIsImmediate() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        handler.setOutcome(.permanentFailure(error: "fatal"))
        try await rig.queue.register(handler: handler)
        let jobId = try await rig.queue.submit(makeSubmission(maxAttempts: 3))

        await rig.queue.start()
        await rig.queue.waitUntilIdle()

        let job = try await rig.repository.job(id: jobId)
        XCTAssertEqual(job?.status, .failed)
        XCTAssertEqual(job?.attempts, 1)
        XCTAssertEqual(handler.runCallCount, 1)
    }

    /// К60, вход 3: арифметика §5 — 30, 60, 120 секунд, потолок 1800, без разброса.
    /// Формула считается ТОЛЬКО там, где исхода нет (восстановление прерванной попытки,
    /// §5 «Прерванная попытка») — у `.retry(after: d)` берётся `d`, проверено отдельно.
    func test_k60_backoffArithmeticMatchesFormulaWithCap() async throws {
        let rig = JobQueueTestRig()
        let now = rig.clock.now()

        for (attemptsBefore, expectedDelay) in [(0, 30.0), (1, 60.0), (2, 120.0), (6, 1800.0)] {
            let stuck = makeRunningRow(
                attempts: attemptsBefore, maxAttempts: 100,
                attemptStartedAt: now, leaseExpiresAt: now.addingTimeInterval(1_000), now: now
            )
            try await rig.repository.insert(stuck)
            await rig.queue.start()
            let recovered = try await rig.repository.job(id: stuck.id)
            XCTAssertEqual(recovered?.status, .pending)
            XCTAssertEqual(recovered?.attempts, attemptsBefore + 1)
            let delay = try XCTUnwrap(recovered?.runAfter.timeIntervalSince(now))
            XCTAssertEqual(delay, expectedDelay, accuracy: 0.001)
        }
    }

    /// `.retry(after: d)` берётся `d`, а не формула — иначе К59/эксплуатация выше давали бы
    /// другой `runAfter`.
    func test_k60_explicitRetryDelayOverridesFormula() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        handler.setOutcome(.retry(after: 12_345, error: "custom"))
        try await rig.queue.register(handler: handler)
        let before = rig.clock.now()
        let jobId = try await rig.queue.submit(makeSubmission(maxAttempts: 10))

        await rig.queue.start()
        await rig.queue.waitUntilIdle()

        let job = try await rig.repository.job(id: jobId)
        let delay = try XCTUnwrap(job?.runAfter.timeIntervalSince(before))
        XCTAssertEqual(delay, 12_345, accuracy: 0.001, "явная задержка исхода, не формула 30*2^(n-1)")
    }

    /// К61: `start()` — четыре строки `running`, разная развилка по `attemptStartedAt`.
    func test_k61_startRestoresFourRunningRowsByAttemptStartedAt() async throws {
        let rig = JobQueueTestRig()
        let now = rig.clock.now()

        // (a) не передавалась обработчику.
        let unstarted = makeRunningRow(
            attempts: 2, maxAttempts: 5, attemptStartedAt: nil,
            leaseExpiresAt: now.addingTimeInterval(100), lastError: "previous", now: now
        )
        // (b) передавалась, есть запас попыток.
        let interrupted = makeRunningRow(
            attempts: 0, maxAttempts: 3, attemptStartedAt: now,
            leaseExpiresAt: now.addingTimeInterval(100), now: now
        )
        // (c) передавалась, попытки будут исчерпаны восстановлением.
        let exhausting = makeRunningRow(
            attempts: 2, maxAttempts: 3, attemptStartedAt: now,
            leaseExpiresAt: now.addingTimeInterval(100), now: now
        )
        // (d) с истёкшим лизингом — та же развилка по отметке, лизинг тут ни при чём.
        let expiredLease = makeRunningRow(
            attempts: 1, maxAttempts: 5, attemptStartedAt: now,
            leaseExpiresAt: now.addingTimeInterval(-100), now: now
        )
        for row in [unstarted, interrupted, exhausting, expiredLease] {
            try await rig.repository.insert(row)
        }

        await rig.queue.start()

        let restoredA = try await rig.repository.job(id: unstarted.id)
        XCTAssertEqual(restoredA?.status, .pending)
        XCTAssertEqual(restoredA?.attempts, 2, "прежний")
        XCTAssertEqual(restoredA?.lastError, "previous", "не тронут")
        XCTAssertNil(restoredA?.leaseExpiresAt)

        let restoredB = try await rig.repository.job(id: interrupted.id)
        XCTAssertEqual(restoredB?.status, .pending)
        XCTAssertEqual(restoredB?.attempts, 1)
        XCTAssertEqual(restoredB?.lastError, "interrupted")

        let restoredC = try await rig.repository.job(id: exhausting.id)
        XCTAssertEqual(restoredC?.status, .failed, "attempts + 1 == maxAttempts — failed, а не pending")
        XCTAssertEqual(restoredC?.attempts, 3)

        let restoredD = try await rig.repository.job(id: expiredLease.id)
        XCTAssertEqual(restoredD?.status, .pending)
        XCTAssertEqual(restoredD?.attempts, 2, "развилка по отметке, не по лизингу")

        for id in [unstarted.id, interrupted.id, exhausting.id, expiredLease.id] {
            let restored = try await rig.repository.job(id: id)
            XCTAssertNotEqual(restored?.status, .running)
        }
    }

    /// К62, первая половина: `leaseExpiresAt` продлевается не реже раза в 30 секунд, пока
    /// задача исполняется.
    ///
    /// MEE-378 (аудит MEE-377): раньше — фиксированная пауза 350 мс, угаданная сверх периода
    /// опроса `renewLeaseWhileRunning` (реальные 0.2 с, `JobQueueEngineExecution.swift`) в
    /// расчёте «должно успеть один раз сработать». Под нагрузкой раннера (см. приёмку MEE-375,
    /// #93 — там же угаданное время однажды подвело) это не гарантия. Заменено опросом самого
    /// условия («лизинг продлён») с ограниченным числом попыток — сигнал, а не тайм-аут: тест
    /// проходит, как только продление ФАКТИЧЕСКИ случилось, и падает по `XCTUnwrap`/`XCTAssert`
    /// с внятным сообщением, если 50 попыток (около секунды) не хватило, а не виснет.
    func test_k62_leaseIsRenewedWhileExecuting() async throws {
        let rig = JobQueueTestRig(leaseSeconds: 40)
        let handler = FakeJobHandler(type: .transcode)
        handler.workLong(seconds: 0.6)
        try await rig.queue.register(handler: handler)
        let start = rig.clock.now()
        let jobId = try await rig.queue.submit(makeSubmission())

        await rig.queue.start()
        rig.clock.set(start.addingTimeInterval(35))

        let expectedFloor = start.addingTimeInterval(35 + 40 - 1)
        var renewed: Job?
        for _ in 0..<50 {
            renewed = try await rig.repository.job(id: jobId)
            if let lease = renewed?.leaseExpiresAt, lease >= expectedFloor {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let renewedLease = try XCTUnwrap(renewed?.leaseExpiresAt, "продление не случилось за 50 опросов (~1 с)")
        XCTAssertGreaterThanOrEqual(
            renewedLease, expectedFloor,
            "продлено от текущего показания часов, а не от момента старта"
        )

        await rig.queue.waitUntilIdle()
    }

    /// Временный тест MEE-378 — снимается перед приёмкой (тот же приём, что
    /// `test_mee363_temporary_k67RepeatedFiftyTimes` перед приёмкой MEE-363): гоняет ровно
    /// сценарий `test_k62_leaseIsRenewedWhileExecuting` выше 50 раз подряд, чтобы отличить
    /// недетерминизм опроса (тогда упал бы один из 50) от однократной случайности.
    func test_mee378_temporary_leaseRenewalPollRepeatedFiftyTimes() async throws {
        for iteration in 0..<50 {
            let rig = JobQueueTestRig(leaseSeconds: 40)
            let handler = FakeJobHandler(type: .transcode)
            handler.workLong(seconds: 0.6)
            try await rig.queue.register(handler: handler)
            let start = rig.clock.now()
            let jobId = try await rig.queue.submit(makeSubmission())

            await rig.queue.start()
            rig.clock.set(start.addingTimeInterval(35))

            let expectedFloor = start.addingTimeInterval(35 + 40 - 1)
            var renewed: Job?
            for _ in 0..<50 {
                renewed = try await rig.repository.job(id: jobId)
                if let lease = renewed?.leaseExpiresAt, lease >= expectedFloor {
                    break
                }
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            let renewedLease = try XCTUnwrap(renewed?.leaseExpiresAt, "повтор \(iteration): продление не случилось")
            XCTAssertGreaterThanOrEqual(renewedLease, expectedFloor, "повтор \(iteration)")
            await rig.queue.waitUntilIdle()
        }
    }

    /// К62, вторая половина: истёкший лизинг возвращает задачу в `pending` той же развилкой,
    /// что инвариант 10 — решение принимает ОЧЕРЕДЬ, вызывая `update` по каждой строке,
    /// возвращённой `reclaimExpiredLeases` «как есть» (К89), а не сам метод порта.
    func test_k62_expiredLeaseBranchesLikeInvariant10ViaQueueDecision() async throws {
        let rig = JobQueueTestRig()
        await rig.queue.start()   // пустое восстановление; isRunning = true

        let now = rig.clock.now()
        let withMark = makeRunningRow(
            attempts: 0, maxAttempts: 5, attemptStartedAt: now,
            leaseExpiresAt: now.addingTimeInterval(-1), now: now
        )
        let withoutMark = makeRunningRow(
            attempts: 1, maxAttempts: 5, attemptStartedAt: nil,
            leaseExpiresAt: now.addingTimeInterval(-1), now: now
        )
        try await rig.repository.insert(withMark)
        try await rig.repository.insert(withoutMark)

        // Триггер пересмотра БЕЗ `start()` — recovery не должна успеть тронуть эти строки
        // раньше `reclaimExpiredLeases`: они появились уже после единственного `start()`.
        _ = try await rig.queue.submit(makeSubmission(
            payload: .attribute(transcriptId: UUID(), meetingId: nil)
        ))

        let recoveredWithMark = try await rig.repository.job(id: withMark.id)
        XCTAssertEqual(recoveredWithMark?.status, .pending)
        XCTAssertEqual(recoveredWithMark?.attempts, 1, "attempts + 1 — попытка передавалась")
        XCTAssertEqual(recoveredWithMark?.lastError, "interrupted")

        let recoveredWithoutMark = try await rig.repository.job(id: withoutMark.id)
        XCTAssertEqual(recoveredWithoutMark?.status, .pending)
        XCTAssertEqual(recoveredWithoutMark?.attempts, 1, "прежний — попытка не передавалась")
    }

    /// К63: отметка ставится непосредственно перед `run`, одной записью, и снимается после
    /// каждого из трёх исходов.
    func test_k63_attemptMarkSetBeforeRunAndClearedAfterEveryOutcome() async throws {
        let outcomes: [JobOutcome] = [.success, .retry(after: 1, error: "e"), .permanentFailure(error: "e")]
        for outcome in outcomes {
            let rig = JobQueueTestRig()
            let handler = FakeJobHandler(type: .transcode)
            handler.setOutcome(outcome)
            try await rig.queue.register(handler: handler)
            let jobId = try await rig.queue.submit(makeSubmission(maxAttempts: 10))

            await rig.queue.start()
            await rig.queue.waitUntilIdle()

            let observed = try XCTUnwrap(handler.observedJobs.first)
            XCTAssertNotNil(observed.attemptStartedAt, "отметка уже непуста в момент вызова run")

            let after = try await rig.repository.job(id: jobId)
            XCTAssertNil(after?.attemptStartedAt, "снята после исхода")
        }
    }

    /// К63, вторая половина: возвращённый заблокированный кандидат (§7 шаг 5) и кандидат,
    /// возвращённый `stop()` (инвариант 12), отметки не получают.
    func test_k63_unstartedCandidatesNeverGetTheMark() async throws {
        let blockedRig = JobQueueTestRig(powerSnapshot: .onBattery)
        let blockedId = try await blockedRig.queue.submit(makeSubmission(requiresACPower: true))
        await blockedRig.queue.start()
        let blocked = try await blockedRig.repository.job(id: blockedId)
        XCTAssertNil(blocked?.attemptStartedAt)

        let stopRig = JobQueueTestRig()
        let now = stopRig.clock.now()
        let claimedNotStarted = makeRunningRow(
            attempts: 0, maxAttempts: 3, attemptStartedAt: nil,
            leaseExpiresAt: now.addingTimeInterval(100), now: now
        )
        try await stopRig.repository.insert(claimedNotStarted)
        await stopRig.queue.start()
        await stopRig.queue.stop()
        let stray = try await stopRig.repository.job(id: claimedNotStarted.id)
        XCTAssertEqual(stray?.status, .pending)
        XCTAssertNil(stray?.attemptStartedAt)
    }
}
