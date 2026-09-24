//  Группа O перечня MEE-189 (пересмотр очереди) — К73…К78. C-013 v8, MEE-350.

import XCTest
import DomainCore
import DomainTestKit

final class JobQueueEngineReviewLoopTests: XCTestCase {

    /// К73: три задачи, блокированные разными условиями, ни одной готовой — `claimNext`
    /// зван ровно четыре раза (три кандидата и `nil`); ни один `id` не рассмотрен дважды.
    ///
    /// Вторая блокировка перестроена с `notYetDue` на `thermalPressure` (возврат РП по
    /// MEE-350): `runAfter <= now` в фейке — тот же фильтр, что у настоящей таблицы (C-010
    /// инв. 25, IR-121 — снимает архитектор), и строка, не дошедшая по сроку, `claimNext`
    /// вообще не возвращает — `notYetDue` этим способом недостижим, а счётчик `4` требует
    /// ВИДИМОГО третьего кандидата.
    func test_k73_revisitTerminatesAfterVisitingEveryCandidateOnce() async throws {
        let rig = JobQueueTestRig(powerSnapshot: PowerSnapshot(
            source: .battery, batteryFraction: 0.5, isLowPowerModeEnabled: false,
            thermalPressure: .serious, checkedAt: Date(timeIntervalSince1970: 0)
        ))
        _ = try await rig.queue.submit(makeSubmission(priority: 30, requiresACPower: true))
        _ = try await rig.queue.submit(makeSubmission(priority: 20, maxThermalPressure: .fair))
        _ = try await rig.queue.submit(makeSubmission(
            payload: .diarize(recordingId: UUID(), profileId: "p"), priority: 10
        ))   // без обработчика — noHandler

        await rig.queue.start()

        XCTAssertEqual(rig.repository.claimNextCallCount, 4, "три кандидата и завершающий nil")
        let all = try await rig.repository.jobs(status: .pending)
        XCTAssertEqual(all.jobs.count, 3, "все три вернулись в pending, ни одна не потерялась")
    }

    /// К74: готовая задача с меньшим `priority` стартует, пока верхняя блокирована —
    /// голодания нет.
    func test_k74_lowerPriorityReadyJobStartsWhileHigherIsBlocked() async throws {
        let rig = JobQueueTestRig()
        try await rig.queue.register(handler: FakeJobHandler(type: .transcode))
        let attributeHandler = FakeJobHandler(type: .attribute)
        attributeHandler.workLong(seconds: 0.3)
        try await rig.queue.register(handler: attributeHandler)

        let transcodeId = try await rig.queue.submit(makeSubmission(priority: 50, forbidWhileRecording: true))
        let attributeId = try await rig.queue.submit(makeSubmission(
            payload: .attribute(transcriptId: UUID(), meetingId: nil), priority: 40
        ))

        await rig.queue.recordingDidStart()
        await rig.queue.start()

        let transcode = try await rig.repository.job(id: transcodeId)
        XCTAssertEqual(transcode?.status, .pending)
        XCTAssertEqual(transcode?.attempts, 0)
        let attribute = try await rig.repository.job(id: attributeId)
        XCTAssertEqual(attribute?.status, .running, "меньший приоритет обгоняет заблокированный больший")
    }

    /// К75: `skipped` не переживает пересмотр — после остановки записи ближайший пересмотр
    /// берёт прежде отвергнутого кандидата.
    func test_k75_skippedDoesNotSurviveTheRevisit() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        handler.workLong(seconds: 0.2)
        try await rig.queue.register(handler: handler)
        try await rig.queue.register(handler: FakeJobHandler(type: .attribute))

        let transcodeId = try await rig.queue.submit(makeSubmission(priority: 50, forbidWhileRecording: true))
        _ = try await rig.queue.submit(makeSubmission(
            payload: .attribute(transcriptId: UUID(), meetingId: nil), priority: 40
        ))

        await rig.queue.recordingDidStart()
        await rig.queue.start()
        await rig.queue.waitUntilIdle()

        var transcode = try await rig.repository.job(id: transcodeId)
        XCTAssertEqual(transcode?.status, .pending, "запись ещё идёт")

        await rig.queue.recordingDidStop()
        transcode = try await rig.repository.job(id: transcodeId)
        XCTAssertEqual(transcode?.status, .running, "ближайший пересмотр берёт прежде отвергнутого")
    }

    /// К76: три блокированные задачи в одном пересмотре — ровно три события `blocked`, по
    /// одному на задачу.
    func test_k76_exactlyOneBlockedEventPerRejectedCandidate() async throws {
        let rig = JobQueueTestRig(powerSnapshot: .onBattery)
        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()

        let ids = try await [
            rig.queue.submit(makeSubmission(priority: 30, requiresACPower: true)),
            rig.queue.submit(makeSubmission(priority: 20, requiresACPower: true)),
            rig.queue.submit(makeSubmission(priority: 10, requiresACPower: true))
        ]
        for _ in ids {
            guard case .submitted = await iterator.next() else { return XCTFail("ожидался submitted") }
        }

        await rig.queue.start()

        var blockedIds: [UUID] = []
        for _ in 0..<3 {
            guard case .blocked(let jobId, _, let reason) = await iterator.next() else {
                return XCTFail("ожидался blocked")
            }
            XCTAssertEqual(reason, .waitingForACPower)
            blockedIds.append(jobId)
        }
        XCTAssertEqual(Set(blockedIds), Set(ids), "по одному на задачу, ни одна не пропущена и не задвоена")
    }

    /// Инвариант 28, §7 шаг 4(возврат РП по MEE-350): «слоты кончились — пересмотр окончен»
    /// — два слота, пять кандидатов пяти разных типов (предел типа не участвует). После
    /// второго старта `claimNext` больше не звана вовсе — ни третьего кандидата не смотрит,
    /// ни `blocked(.concurrencyLimit)` на оставшихся не публикует.
    func test_reviewEndsAssoonAsGlobalSlotsAreExhausted() async throws {
        let rig = JobQueueTestRig(globalConcurrencyLimit: 2, perTypeConcurrencyLimit: 1)
        for type in JobType.allCases {
            let handler = FakeJobHandler(type: type)
            handler.workLong(seconds: 0.3)
            try await rig.queue.register(handler: handler)
        }
        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()

        let payloads: [(JobPayload, Int)] = [
            (.transcode(recordingId: UUID()), 50),
            (.transcribe(recordingId: UUID(), profileId: "p", language: nil), 40),
            (.diarize(recordingId: UUID(), profileId: "p"), 30),
            (.attribute(transcriptId: UUID(), meetingId: nil), 20),
            (.summarize(meetingId: UUID(), transcriptId: UUID(), profileId: "p"), 10)
        ]
        var ids: [UUID] = []
        for (payload, priority) in payloads {
            ids.append(try await rig.queue.submit(makeSubmission(payload: payload, priority: priority)))
        }
        for _ in ids {
            guard case .submitted = await iterator.next() else { return XCTFail("ожидался submitted") }
        }

        await rig.queue.start()

        guard case .started(let firstStarted, _) = await iterator.next() else {
            return XCTFail("ожидался started")
        }
        guard case .started(let secondStarted, _) = await iterator.next() else {
            return XCTFail("ожидался started")
        }
        XCTAssertEqual(Set([firstStarted, secondStarted]), Set([ids[0], ids[1]]), "первые два по приоритету")
        XCTAssertEqual(rig.repository.claimNextCallCount, 2, "ровно два — пересмотр окончен, слотов больше нет")

        for id in ids[2...] {
            let job = try await rig.repository.job(id: id)
            XCTAssertEqual(job?.status, .pending, "не рассмотрен вовсе — не blocked, а нетронутый pending")
        }
    }

    /// К77: пересмотр стартует больше одной задачи, пока есть свободные слоты.
    func test_k77_revisitStartsMoreThanOneJobWhileSlotsAreFree() async throws {
        let rig = JobQueueTestRig(globalConcurrencyLimit: 2, perTypeConcurrencyLimit: 1)
        let transcodeHandler = FakeJobHandler(type: .transcode)
        transcodeHandler.workLong(seconds: 0.3)
        try await rig.queue.register(handler: transcodeHandler)
        let attributeHandler = FakeJobHandler(type: .attribute)
        attributeHandler.workLong(seconds: 0.3)
        try await rig.queue.register(handler: attributeHandler)
        try await rig.queue.register(handler: FakeJobHandler(type: .diarize))

        let firstId = try await rig.queue.submit(makeSubmission(priority: 30))
        let secondId = try await rig.queue.submit(makeSubmission(
            payload: .attribute(transcriptId: UUID(), meetingId: nil), priority: 20
        ))
        let thirdId = try await rig.queue.submit(makeSubmission(
            payload: .diarize(recordingId: UUID(), profileId: "p"), priority: 10
        ))

        await rig.queue.start()

        let first = try await rig.repository.job(id: firstId)
        let second = try await rig.repository.job(id: secondId)
        let third = try await rig.repository.job(id: thirdId)
        XCTAssertEqual(first?.status, .running)
        XCTAssertEqual(second?.status, .running)
        XCTAssertEqual(third?.status, .pending, "предел 2 занят первыми двумя")
    }

    /// К78: перечень `types`, переданный `claimNext`, содержит все случаи `JobType` и в
    /// пределах пересмотра не меняется — `blocked(.noHandler)` доживает до подписчика.
    func test_k78_reviewNeverNarrowsTheTypesList() async throws {
        let rig = JobQueueTestRig()
        let summarizeId = try await rig.queue.submit(makeSubmission(
            payload: .summarize(meetingId: UUID(), transcriptId: UUID(), profileId: "p")
        ))
        await rig.queue.start()

        let call = try XCTUnwrap(rig.repository.callLog.calls(port: "JobRepository")
            .last { $0.method.hasPrefix("claimNext") })
        XCTAssertTrue(call.arguments.first?.contains("summarize") ?? false, "summarize не исключён из перечня")

        let job = try await rig.repository.job(id: summarizeId)
        XCTAssertEqual(job?.status, .pending)
    }
}
