//  Группа M перечня MEE-189 (отмена, регистрация, события) — К64…К69. C-013 v8, MEE-350.

import XCTest
import DomainCore
import DomainTestKit

final class JobQueueEngineCancelEventsTests: XCTestCase {

    /// К64: `cancel` по пяти статусам.
    func test_k64_cancelBehavesPerStatus() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        handler.workLong(seconds: 0.3)
        try await rig.queue.register(handler: handler)

        let pendingId = try await rig.queue.submit(makeSubmission(
            runAfter: rig.clock.now().addingTimeInterval(1_000)
        ))
        try await rig.queue.cancel(jobId: pendingId)
        let cancelledPending = try await rig.repository.job(id: pendingId)
        XCTAssertEqual(cancelledPending?.status, .cancelled, "pending — cancelled немедленно")

        let runningId = try await rig.queue.submit(makeSubmission(priority: 10))
        await rig.queue.start()
        let runningBefore = try await rig.repository.job(id: runningId)
        XCTAssertEqual(runningBefore?.status, .running, "вектор непустоты: задача правда исполняется")
        try await rig.queue.cancel(jobId: runningId)
        let stillRunning = try await rig.repository.job(id: runningId)
        XCTAssertEqual(stillRunning?.status, .running, "cancelled — после возврата Task, а не до")
        await rig.queue.waitUntilIdle()
        let cancelledRunning = try await rig.repository.job(id: runningId)
        XCTAssertEqual(cancelledRunning?.status, .cancelled)

        // Строки вставлены НАПРЯМУЮ, а не через `submit`: очередь уже `isRunning`, и
        // `submit` сам запустил бы пересмотр, который забрал бы задачу раньше, чем тест
        // успеет проверить «операция без эффекта» на терминальном статусе.
        for terminal in [JobStatus.succeeded, .failed, .cancelled] {
            let now = rig.clock.now()
            let terminalJob = Job(
                id: UUID(), type: .transcode, payload: .transcode(recordingId: UUID()), status: terminal,
                priority: 0, attempts: 1, maxAttempts: 3, runAfter: now,
                conditions: JobConditions(
                    requiresACPower: false, forbidWhileRecording: false,
                    maxThermalPressure: .critical, requiresProfileReady: nil
                ),
                dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil,
                createdAt: now, updatedAt: now
            )
            try await rig.repository.insert(terminalJob)
            try await rig.queue.cancel(jobId: terminalJob.id)   // без эффекта, а не ошибка
            let unchanged = try await rig.repository.job(id: terminalJob.id)
            XCTAssertEqual(unchanged?.status, terminal, "\(terminal) — операция без эффекта")
        }
    }

    /// К65: `cancel` неизвестного идентификатора даёт `unknownJob` с тем же идентификатором.
    func test_k65_cancelUnknownJobThrowsWithSameId() async throws {
        let rig = JobQueueTestRig()
        let unknownId = UUID()
        do {
            try await rig.queue.cancel(jobId: unknownId)
            XCTFail("ожидался unknownJob")
        } catch JobQueueError.unknownJob(let id) {
            XCTAssertEqual(id, unknownId)
        }
    }

    /// К66: `register` дважды для одного `JobType` даёт `handlerAlreadyRegistered`; первый
    /// обработчик остаётся действующим; другой тип регистрируется свободно.
    func test_k66_registerTwiceForSameTypeIsRejected() async throws {
        let rig = JobQueueTestRig()
        let first = FakeJobHandler(type: .transcode)
        try await rig.queue.register(handler: first)

        let second = FakeJobHandler(type: .transcode)
        do {
            try await rig.queue.register(handler: second)
            XCTFail("ожидался handlerAlreadyRegistered")
        } catch JobQueueError.handlerAlreadyRegistered(let type) {
            XCTAssertEqual(type, .transcode)
        }

        try await rig.queue.register(handler: FakeJobHandler(type: .attribute))   // проходит

        let jobId = try await rig.queue.submit(makeSubmission())
        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        XCTAssertEqual(first.runCallCount, 1, "первый обработчик остаётся действующим")
        XCTAssertEqual(second.runCallCount, 0)
        _ = jobId
    }

    /// К67: нет обработчика — `blocked(.noHandler)` на каждом пересмотре, задача не
    /// исполняется, соседние готовые задачи стартуют в том же пересмотре.
    func test_k67_noHandlerBlocksWithoutStallingTheRest() async throws {
        let rig = JobQueueTestRig()
        let attributeHandler = FakeJobHandler(type: .attribute)
        try await rig.queue.register(handler: attributeHandler)

        let summarizeId = try await rig.queue.submit(makeSubmission(
            payload: .summarize(meetingId: UUID(), transcriptId: UUID(), profileId: "p")
        ))
        let readyId = try await rig.queue.submit(makeSubmission(
            payload: .attribute(transcriptId: UUID(), meetingId: nil)
        ))

        for _ in 0..<3 {
            await rig.queue.start()
            // `waitUntilIdle()` — иначе фоновое завершение `readyId` (пересмотр по
            // завершении, §7) гонится с этим прямым чтением: между `claimNext` и её же
            // разворотом `noHandler` строка мгновенно, но НАБЛЮДАЕМО, побывала `running`.
            await rig.queue.waitUntilIdle()
            let summarizeJob = try await rig.repository.job(id: summarizeId)
            XCTAssertEqual(summarizeJob?.status, .pending)
            XCTAssertEqual(summarizeJob?.attempts, 0)
        }
        let ready = try await rig.repository.job(id: readyId)
        XCTAssertEqual(ready?.status, .succeeded, "пересмотр не встал на noHandler")
    }

    /// К68: ровно одна финальная последовательность на исполненную задачу —
    /// `started → (progressed*) → одно из succeeded|failed|cancelled`.
    func test_k68_exactlyOneFinalSequencePerExecutedJob() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        try await rig.queue.register(handler: handler)
        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()

        // Успех.
        handler.setOutcome(.success)
        let successId = try await rig.queue.submit(makeSubmission())
        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        var events = await drain(&iterator, until: successId, count: 5)
        assertSingleFinalSequence(events, jobId: successId, final: .succeeded)

        // Retry, доведённый до failed.
        handler.setOutcome(.retry(after: 1, error: "e"))
        let retryId = try await rig.queue.submit(makeSubmission(maxAttempts: 1))
        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        events = await drain(&iterator, until: retryId, count: 5)
        assertSingleFinalSequence(events, jobId: retryId, final: .failed)

        // Отмена во время исполнения.
        handler.setOutcome(.success)
        handler.workLong(seconds: 0.3)
        let cancelId = try await rig.queue.submit(makeSubmission(priority: 5))
        await rig.queue.start()
        try await rig.queue.cancel(jobId: cancelId)
        await rig.queue.waitUntilIdle()
        events = await drain(&iterator, until: cancelId, count: 5)
        assertSingleFinalSequence(events, jobId: cancelId, final: .cancelled)
    }

    /// К69: `progressed(fraction:)` лежит в `0...1` — значения вне диапазона зажимаются.
    func test_k69_progressIsClampedToUnitRange() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        handler.setProgressSteps([-0.1, 0, 0.5, 1, 1.1])
        try await rig.queue.register(handler: handler)
        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()

        _ = try await rig.queue.submit(makeSubmission())
        await rig.queue.start()
        await rig.queue.waitUntilIdle()

        var fractions: [Double] = []
        for _ in 0..<7 {
            guard case .progressed(_, let fraction) = await iterator.next() else { continue }
            fractions.append(fraction)
        }
        XCTAssertEqual(fractions, [0, 0, 0.5, 1, 1])
        XCTAssertTrue(fractions.allSatisfy { (0...1).contains($0) })
    }

    // MARK: - Оснастка

    private func drain(
        _ iterator: inout AsyncStream<JobEvent>.AsyncIterator, until jobId: UUID, count: Int
    ) async -> [JobEvent] {
        var collected: [JobEvent] = []
        for _ in 0..<count {
            guard let event = await iterator.next() else { break }
            collected.append(event)
            if case .succeeded(let id, _) = event, id == jobId { break }
            if case .failed(let id, _, _, let willRetry) = event, id == jobId, !willRetry { break }
            if case .cancelled(let id, _) = event, id == jobId { break }
        }
        return collected
    }

    private func assertSingleFinalSequence(_ events: [JobEvent], jobId: UUID, final: JobStatus) {
        let own = events.filter { event in
            switch event {
            case .started(let id, _), .progressed(let id, _), .succeeded(let id, _),
                 .cancelled(let id, _):
                return id == jobId
            case .failed(let id, _, _, _):
                return id == jobId
            case .submitted, .blocked:
                return false
            }
        }
        guard case .started = own.first else {
            return XCTFail("первое событие своей задачи обязано быть started")
        }
        let finals = own.filter {
            switch $0 {
            case .succeeded, .failed, .cancelled: return true
            default: return false
            }
        }
        XCTAssertEqual(finals.count, 1, "ровно одно финальное событие")
    }
}
