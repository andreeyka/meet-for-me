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
    ///
    /// Возврат РП по MEE-350: прежний `drain` останавливался на ПЕРВОМ финальном событии
    /// задачи — `finals.count == 1` было верно всегда, независимо от реализации. Теперь
    /// после `waitUntilIdle()` поток дочитывается ДО КОНЦА — с таймаутом на каждый
    /// `next()` (см. `drainUntilQuiet`), а не бесконечным ожиданием: `AsyncStream`, которую
    /// никто не `finish()`ит, иначе повторила бы зависание CI по этой же ветке.
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
        var events = await drainUntilQuiet(&iterator)
        assertSingleFinalSequence(events, jobId: successId, final: .succeeded)

        // Retry, доведённый до failed.
        handler.setOutcome(.retry(after: 1, error: "e"))
        let retryId = try await rig.queue.submit(makeSubmission(maxAttempts: 1))
        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        events = await drainUntilQuiet(&iterator)
        assertSingleFinalSequence(events, jobId: retryId, final: .failed)

        // Отмена во время исполнения.
        handler.setOutcome(.success)
        handler.workLong(seconds: 0.3)
        let cancelId = try await rig.queue.submit(makeSubmission(priority: 5))
        await rig.queue.start()
        try await rig.queue.cancel(jobId: cancelId)
        await rig.queue.waitUntilIdle()
        events = await drainUntilQuiet(&iterator)
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

    /// Обёртка-класс вокруг итератора — только чтобы избежать «mutable capture of inout
    /// parameter is not allowed in concurrently-executing code» при захвате в `Task { }`
    /// (тот же приём, что и в `JobQueueTestRig`): захватывать можно ссылочный тип, не сам
    /// `inout`-параметр.
    private final class EventIteratorBox: @unchecked Sendable {
        var iterator: AsyncStream<JobEvent>.AsyncIterator
        init(_ iterator: AsyncStream<JobEvent>.AsyncIterator) { self.iterator = iterator }
        func next() async -> JobEvent? { await iterator.next() }
    }

    /// Дочитывает поток ДО КОНЦА текущей партии — то есть пока события идут; останавливается,
    /// как только `next()` не возвращает событие за `timeout` секунд, а не на первом
    /// «интересном» событии (возврат РП по MEE-350, К68). Таймаут — реальные часы через
    /// `Task.sleep`, не `ManualClock`: события публикуются фоновыми `Task`, не продвигаются
    /// вручную. Поток никогда не `finish()`ится, поэтому голый `await iterator.next()` без
    /// таймаута рискует зависнуть навсегда — тот же класс проблемы, что уже вызывал зависания
    /// CI раньше в этой сессии.
    private func drainUntilQuiet(
        _ iterator: inout AsyncStream<JobEvent>.AsyncIterator, timeout: Double = 0.5
    ) async -> [JobEvent] {
        let box = EventIteratorBox(iterator)
        var collected: [JobEvent] = []
        while true {
            let nextTask = Task { await box.next() }
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                nextTask.cancel()
            }
            let event = await nextTask.value
            timeoutTask.cancel()
            guard let event else { break }
            collected.append(event)
        }
        iterator = box.iterator
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
