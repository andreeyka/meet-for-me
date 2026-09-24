//  Группа M перечня MEE-189 (отмена, регистрация, события) — К64…К69. C-013 v8, MEE-350.

import XCTest
@testable import DomainCore
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
    ///
    /// Возврат РП по MEE-357: прежняя версия проверяла только конечное состояние строки
    /// (`.pending`, `attempts == 0`) — «пересмотр не встал» читалось лишь по тому, что
    /// `readyId` в итоге дошла до `succeeded`. Теперь читается событие `blocked(.noHandler)`
    /// САМО, и то, что `started(readyId)` публикуется в пересмотре 1, а не отложен.
    ///
    /// MEE-363 (найдено красным main после #86, дважды): `start()` НЕ ждёт исполнение
    /// `readyId` — оно идёт отдельной `Task` (§7, `beginExecuting`), и эта `Task` — НАСТОЯЩИЙ
    /// параллелизм (кооперативный пул Swift даёт ей отдельный поток, а не только очередь
    /// приостановок ОДНОГО актора): с фейковым нулевым временем исполнения она может успеть
    /// завершиться и завести СВОЙ пересмотр по завершении быстрее, чем этот тест прочитает
    /// хоть что-то — порядок между её событиями и событиями пересмотра 1 после этой границы
    /// НЕ определён языком и потому не проверяется здесь. Определено ЧИСЛО (ровно четыре
    /// события до полного оседания — по два на каждый пересмотр: `started`/`blocked` у
    /// первого, `succeeded`/`blocked` у второго, §7 требует оба безусловно) и ПРИЧИННЫЙ
    /// порядок ВНУТРИ одной задачи (`started(readyId)` раньше `succeeded(readyId)`) и МЕЖДУ
    /// пересмотрами (мьютекс `isRevisitLoopRunning`, `JobQueueEngineReview.swift`, не пускает
    /// второй пересмотр раньше конца первого — отсюда второе `blocked(summarize)` всегда
    /// последнее). `waitUntilIdle()` — единственная граница, которую очередь даёт для
    /// «оба пересмотра точно окончены»; до неё фиксированного числа событий не существует.
    func test_k67_noHandlerBlocksWithoutStallingTheRest() async throws {
        let rig = JobQueueTestRig()
        let attributeHandler = FakeJobHandler(type: .attribute)
        try await rig.queue.register(handler: attributeHandler)
        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()

        let summarizeId = try await rig.queue.submit(makeSubmission(
            payload: .summarize(meetingId: UUID(), transcriptId: UUID(), profileId: "p")
        ))
        let readyId = try await rig.queue.submit(makeSubmission(
            payload: .attribute(transcriptId: UUID(), meetingId: nil)
        ))
        _ = await drainExactly(&iterator, count: 2)   // два submitted — не предмет этого критерия

        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        let settled = await drainExactly(&iterator, count: 4)

        let blockedSummarize = JobEvent.blocked(jobId: summarizeId, type: .summarize, reason: .noHandler)
        let startedReady = JobEvent.started(jobId: readyId, type: .attribute)
        let succeededReady = JobEvent.succeeded(jobId: readyId, type: .attribute)
        XCTAssertEqual(
            settled.filter { $0 == blockedSummarize }.count, 2,
            "К67: blocked(.noHandler) публикуется на пересмотре 1 И на пересмотре по " +
            "завершении readyId — оба безусловны (§7)"
        )
        XCTAssertTrue(settled.contains(startedReady), "К67: сосед стартовал, а не отложен")
        XCTAssertTrue(settled.contains(succeededReady), "readyId исполнилась до успеха")
        XCTAssertEqual(
            settled.last, blockedSummarize,
            "второй пересмотр не начинается раньше конца первого (мьютекс) — его blocked " +
            "последним и оседает"
        )
        let startedIndex = try XCTUnwrap(settled.firstIndex(of: startedReady))
        let succeededIndex = try XCTUnwrap(settled.firstIndex(of: succeededReady))
        XCTAssertLessThan(startedIndex, succeededIndex, "readyId стартует раньше, чем успевает")

        let summarizeAfterSettling = try await rig.repository.job(id: summarizeId)
        XCTAssertEqual(summarizeAfterSettling?.status, .pending)
        XCTAssertEqual(summarizeAfterSettling?.attempts, 0)

        // Пересмотры 3 и 4 — summarizeId остаётся единственным кандидатом: блокируется на
        // каждом внешнем start(), ни один пересмотр не зависает.
        for _ in 0..<2 {
            try await assertNextPassOnlyBlocksNoHandler(rig, summarizeId: summarizeId, iterator: &iterator)
        }

        let ready = try await rig.repository.job(id: readyId)
        XCTAssertEqual(ready?.status, .succeeded, "пересмотр не встал на noHandler")
    }

    /// MEE-375 (найдено РП на приёмке #91, MEE-363): заявка `revisitPassRequested`,
    /// оставленная гонкой ровно в момент, когда пересмотр уже видит `isRunning == false`,
    /// была бы у СТАРОГО кода прочитана и НЕ сброшена — `guard revisitPassRequested,
    /// isRunning else { return }` выходил на ветке `isRunning == false`, не долистав до
    /// строки сброса, стоявшей ПОСЛЕ него. Повисшая заявка переживала `stop()`, и следующий
    /// явный `start()` видел её как СВОЮ, только что оставленную, — заводил пересмотр,
    /// которого никто не просил, и публиковал лишний `blocked(.noHandler)`.
    ///
    /// Сама гонка — та же истинная параллельность (readyId с нулевой задержкой), что в
    /// MEE-363, и настолько же недетерминированна на публичном API. Здесь она воспроизведена
    /// напрямую: `performRevisitSweepForTest(withPendingRequest:)` (только для теста, см.
    /// `JobQueueEngineReview.swift`) заводит заявку и зовёт `performRevisitSweep()` одним
    /// изолированным вызовом, ПОСЛЕ `stop()` — обычные вызывающие (`runRevisitPass()`,
    /// `fulfillRequestedRevisitSweep()`, хвост `executeAndFinish`) сами не пускают его при
    /// `isRunning == false`, так что напрямую эту границу иначе не застать. Проверяется
    /// именно тело метода на этой границе, а не удача гонки с планировщиком.
    func test_mee375_stopClearsPendingRevisitRequestSoNextStartDoesNotDoubleBlock() async throws {
        let rig = JobQueueTestRig()
        let summarizeId = try await rig.queue.submit(makeSubmission(
            payload: .summarize(meetingId: UUID(), transcriptId: UUID(), profileId: "p")
        ))
        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()
        _ = await drainExactly(&iterator, count: 1)   // submitted — не предмет этого теста

        await rig.queue.start()
        _ = await drainExactly(&iterator, count: 1)   // blocked(.noHandler) обычного захода
        await rig.queue.stop()

        await rig.queue.performRevisitSweepForTest(withPendingRequest: true)
        let stillRequested = await rig.queue.revisitPassRequested
        XCTAssertFalse(stillRequested, "МЕЕ-375: заявка обязана сняться, даже когда isRunning уже false")

        await rig.queue.start()
        let afterRestart = await drainExactly(&iterator, count: 1)
        XCTAssertEqual(
            afterRestart, [.blocked(jobId: summarizeId, type: .summarize, reason: .noHandler)],
            "МЕЕ-375: ровно один blocked на явный запуск — повисшая заявка не должна " +
            "заводить второй"
        )
        await rig.queue.waitUntilIdle()
        // Второй `start()` этого теста (см. довод выше) иначе оставляет свои `timerTask`/
        // `powerEventsTask` без парного `stop()` до конца функции — тот же класс утечки,
        // что предупреждает `deinit` `JobQueueEngine.swift` (найдено РП на приёмке #91).
        await rig.queue.stop()
    }

    private func assertNextPassOnlyBlocksNoHandler(
        _ rig: JobQueueTestRig, summarizeId: UUID, iterator: inout AsyncStream<JobEvent>.AsyncIterator
    ) async throws {
        await rig.queue.start()
        let pass = await drainExactly(&iterator, count: 1)
        XCTAssertEqual(pass, [.blocked(jobId: summarizeId, type: .summarize, reason: .noHandler)])
        let summarizeJob = try await rig.repository.job(id: summarizeId)
        XCTAssertEqual(summarizeJob?.status, .pending)
        XCTAssertEqual(summarizeJob?.attempts, 0)
        await rig.queue.waitUntilIdle()
    }

    /// К68: ровно одна финальная последовательность на исполненную задачу —
    /// `started → (progressed*) → одно из succeeded|failed|cancelled`.
    ///
    /// Возврат РП по MEE-350: прежний `drain` останавливался на ПЕРВОМ финальном событии
    /// задачи — `finals.count == 1` было верно всегда, независимо от реализации.
    ///
    /// Первая попытка чинить таймаутом на каждый `next()` (гонка `Task` через отмену)
    /// упала на этой же ветке в CI неверным порядком событий (первым own-событием
    /// оказался не `started`) — без компилятора под рукой причину гонки внутри отмены
    /// `AsyncStream.AsyncIterator` не установить надёжно, и снова рисковать зависанием
    /// той же веткой не стоило. Взамен — фиксированный счётчик `submitted`+`started`+
    /// финал (три события на сценарий), а не таймаут: после `waitUntilIdle()` все три уже
    /// лежат в буфере (`JobEventBroadcaster.publish` — синхронный `continuation.yield`), и
    /// ни один сценарий не задаёт `setProgressSteps` — по исходнику `FakeJobHandler.run`
    /// `progress` без него не зовётся вовсе. Читаем ВЕСЬ пакет, а не «до первого
    /// подходящего»: `finals.count` считается по всем трём, а не по одному, на котором
    /// прежний `drain` останавливался, — ровно то, что было названо тривиальным.
    func test_k68_exactlyOneFinalSequencePerExecutedJob() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        try await rig.queue.register(handler: handler)
        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()

        // Успех: submitted + started + succeeded.
        handler.setOutcome(.success)
        let successId = try await rig.queue.submit(makeSubmission())
        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        var events = await drainExactly(&iterator, count: 3)
        assertSingleFinalSequence(events, jobId: successId, final: .succeeded)

        // Retry, доведённый до failed, — теми же тремя.
        handler.setOutcome(.retry(after: 1, error: "e"))
        let retryId = try await rig.queue.submit(makeSubmission(maxAttempts: 1))
        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        events = await drainExactly(&iterator, count: 3)
        assertSingleFinalSequence(events, jobId: retryId, final: .failed)

        // Отмена во время исполнения — теми же тремя (сам `cancel()` ничего не публикует).
        handler.setOutcome(.success)
        handler.workLong(seconds: 0.3)
        let cancelId = try await rig.queue.submit(makeSubmission(priority: 5))
        await rig.queue.start()
        try await rig.queue.cancel(jobId: cancelId)
        await rig.queue.waitUntilIdle()

        // Возврат РП по MEE-350: `drainExactly(count: 3)` сам по себе не отличает «у
        // cancelId ровно три события» от «есть и четвёртое, но мы его молча не прочли» —
        // счётчик просто останавливается. Задача-метка после третьего сценария — независимый
        // `submitted`, и если бы у cancelId было что-то сверх трёх, оно оказалось бы на месте
        // четвёртого прочитанного события, а не сама метка.
        let markerId = try await rig.queue.submit(makeSubmission(priority: -100))
        events = await drainExactly(&iterator, count: 4)
        assertSingleFinalSequence(Array(events.prefix(3)), jobId: cancelId, final: .cancelled)
        guard case .submitted(let markerSubmittedId, _) = events[3] else {
            return XCTFail("четвёртое событие обязано быть submitted метки — ничего от cancelId сверх трёх")
        }
        XCTAssertEqual(markerSubmittedId, markerId)
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

    /// Читает РОВНО `count` событий — весь объявленный пакет сценария, а не «до первого
    /// подходящего» (возврат РП по MEE-350, К68). Без таймаута НАРОЧНО: счётчик — не
    /// приблизительная граница, а число событий, которое сценарий действительно публикует
    /// (см. вызовы в К68) — после `waitUntilIdle()` они уже все лежат в буфере
    /// `AsyncStream` (`JobEventBroadcaster.publish` — синхронный `continuation.yield`), и
    /// лишнего `next()` сверх этого числа здесь нет. `AsyncStream`, которую никто не
    /// `finish()`ит, на лишний `next()` не вернёт `nil` — виснет навсегда, поэтому счётчик
    /// обязан РОВНО совпадать, а не превышать его «на всякий случай».
    private func drainExactly(
        _ iterator: inout AsyncStream<JobEvent>.AsyncIterator, count: Int
    ) async -> [JobEvent] {
        var collected: [JobEvent] = []
        for _ in 0..<count {
            guard let event = await iterator.next() else { break }
            collected.append(event)
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
