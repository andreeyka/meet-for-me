//  Группа K перечня MEE-189 (готовность к запуску и предикат профиля) — К53…К58.
//  C-013 v8, MEE-350.
//
//  Во всех тестах предпосылки (питание, каталог, регистрация обработчиков, постановка)
//  заводятся ДО первого `start()`: `submit` сам запускает пересмотр, только если очередь
//  уже `isRunning`, — до первого `start()` он этого не делает, и порядок подготовки не
//  гонится с состоянием, которое эта же подготовка меняет.

import XCTest
import DomainCore
import DomainTestKit

final class JobQueueEngineReadinessTests: XCTestCase {

    /// К53: готовность — конъюнкция шести клауз; снятие любой одной её ломает, седьмой вход
    /// (все выполнены) исполняется.
    func test_k53_readinessIsAConjunctionOfSixClauses() async throws {
        // (i) status != .pending — cancelled её исключает.
        do {
            let rig = JobQueueTestRig()
            let handler = FakeJobHandler(type: .transcode)
            try await rig.queue.register(handler: handler)
            let id = try await rig.queue.submit(makeSubmission())
            try await rig.queue.cancel(jobId: id)
            await rig.queue.start()
            XCTAssertEqual(handler.runCallCount, 0, "cancelled задача не исполняется")
        }
        // (ii) runAfter > now.
        do {
            let rig = JobQueueTestRig()
            let handler = FakeJobHandler(type: .transcode)
            try await rig.queue.register(handler: handler)
            _ = try await rig.queue.submit(makeSubmission(runAfter: rig.clock.now().addingTimeInterval(3_600)))
            await rig.queue.start()
            XCTAssertEqual(handler.runCallCount, 0)
        }
        // (iii) обработчик типа не зарегистрирован.
        do {
            let rig = JobQueueTestRig()
            let id = try await rig.queue.submit(makeSubmission())
            await rig.queue.start()
            let job = try await rig.repository.job(id: id)
            XCTAssertEqual(job?.status, .pending)
        }
        // (iv) превышен maxConcurrent ТИПА — два transcode при пределе типа 1.
        do {
            let rig = JobQueueTestRig(globalConcurrencyLimit: 2, perTypeConcurrencyLimit: 1)
            let handler = FakeJobHandler(type: .transcode)
            handler.workLong(seconds: 5)
            try await rig.queue.register(handler: handler)
            _ = try await rig.queue.submit(makeSubmission(priority: 10))
            let secondId = try await rig.queue.submit(makeSubmission(priority: 5))
            await rig.queue.start()
            let second = try await rig.repository.job(id: secondId)
            XCTAssertEqual(second?.status, .pending, "предел типа 1 уже занят первой задачей")
        }
        // (v) превышен ГЛОБАЛЬНЫЙ предел — разные типы, предел 1.
        do {
            let rig = JobQueueTestRig(globalConcurrencyLimit: 1, perTypeConcurrencyLimit: 1)
            let transcodeHandler = FakeJobHandler(type: .transcode)
            transcodeHandler.workLong(seconds: 5)
            try await rig.queue.register(handler: transcodeHandler)
            try await rig.queue.register(handler: FakeJobHandler(type: .attribute))
            _ = try await rig.queue.submit(makeSubmission(priority: 10))
            let secondId = try await rig.queue.submit(makeSubmission(
                payload: .attribute(transcriptId: UUID(), meetingId: nil), priority: 5
            ))
            await rig.queue.start()
            let second = try await rig.repository.job(id: secondId)
            XCTAssertEqual(second?.status, .pending, "глобальный предел 1 уже занят")
        }
        // (vi) одно из четырёх условий JobConditions не выполнено — requiresACPower на battery.
        do {
            let rig = JobQueueTestRig(powerSnapshot: PowerSnapshot(
                source: .battery, batteryFraction: 0.5, isLowPowerModeEnabled: false,
                thermalPressure: .nominal, checkedAt: Date(timeIntervalSince1970: 0)
            ))
            try await rig.queue.register(handler: FakeJobHandler(type: .transcode))
            let id = try await rig.queue.submit(makeSubmission(requiresACPower: true))
            await rig.queue.start()
            let job = try await rig.repository.job(id: id)
            XCTAssertEqual(job?.status, .pending)
        }
        // (vii) седьмой вход — всё выполнено.
        do {
            let rig = JobQueueTestRig()
            let handler = FakeJobHandler(type: .transcode)
            handler.workLong(seconds: 5)
            try await rig.queue.register(handler: handler)
            let id = try await rig.queue.submit(makeSubmission())
            await rig.queue.start()
            let job = try await rig.repository.job(id: id)
            XCTAssertEqual(job?.status, .running)
        }
    }

    /// К54: невыполненное условие не расходует попытку, сколько бы пересмотров ни прошло.
    func test_k54_unmetConditionNeverConsumesAnAttempt() async throws {
        let rig = JobQueueTestRig()
        let jobId = try await rig.queue.submit(makeSubmission(
            runAfter: rig.clock.now().addingTimeInterval(1_000)
        ))

        for _ in 0..<3 {
            await rig.queue.start()
            let job = try await rig.repository.job(id: jobId)
            XCTAssertEqual(job?.status, .pending)
            XCTAssertEqual(job?.attempts, 0, "попытка не расходуется невыполненным условием")
            XCTAssertNil(job?.leaseExpiresAt)
        }
    }

    /// К55: стартует первый ПРОШЕДШИЙ условия кандидат, а не первый по порядку приоритета.
    /// `workLong` — тем же приёмом, что К53 (iv)/(v): без него исполнение по умолчанию
    /// заканчивается раньше, чем тест успевает прочесть `.running`, — утверждение гонится
    /// с фоновой `Task`, которую `start()` не ждёт (см. шапку `JobQueueTestRig`).
    func test_k55_firstCandidateThatPassesConditionsStarts() async throws {
        let rig = JobQueueTestRig(powerSnapshot: PowerSnapshot(
            source: .battery, batteryFraction: 0.5, isLowPowerModeEnabled: false,
            thermalPressure: .nominal, checkedAt: Date(timeIntervalSince1970: 0)
        ))
        let handler = FakeJobHandler(type: .transcode)
        handler.workLong(seconds: 5)
        try await rig.queue.register(handler: handler)

        let blockedId = try await rig.queue.submit(makeSubmission(priority: 50, requiresACPower: true))
        let passingId = try await rig.queue.submit(makeSubmission(priority: 40))
        _ = try await rig.queue.submit(makeSubmission(priority: 30))

        await rig.queue.start()

        let blocked = try await rig.repository.job(id: blockedId)
        XCTAssertEqual(blocked?.status, .pending, "приоритет 50 не проходит условие — возвращён")
        let passing = try await rig.repository.job(id: passingId)
        XCTAssertEqual(passing?.status, .running, "приоритет 40 — первый прошедший условия")
    }

    /// К56: не проходит `notYetDue` И `waitingForACPower` одновременно — публикуется ровно
    /// один `blocked` с причиной `notYetDue`, первой по порядку случаев.
    func test_k56_notYetDueWinsOverWaitingForACPower() async throws {
        let rig = JobQueueTestRig(powerSnapshot: PowerSnapshot(
            source: .battery, batteryFraction: 0.5, isLowPowerModeEnabled: false,
            thermalPressure: .nominal, checkedAt: Date(timeIntervalSince1970: 0)
        ))
        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()

        _ = try await rig.queue.submit(makeSubmission(
            runAfter: rig.clock.now().addingTimeInterval(1_000), requiresACPower: true
        ))
        guard case .submitted = await iterator.next() else {
            return XCTFail("ожидался submitted")
        }

        await rig.queue.start()
        guard case .blocked(_, _, let reason) = await iterator.next() else {
            return XCTFail("ожидался blocked")
        }
        XCTAssertEqual(reason, .notYetDue, "notYetDue раньше waitingForACPower по порядку случаев")
    }

    /// К56, вторая половина: не проходит `recordingInProgress` И `profileNotReady`
    /// одновременно — причина `recordingInProgress`, она раньше по порядку случаев.
    func test_k56_recordingInProgressWinsOverProfileNotReady() async throws {
        let rig = JobQueueTestRig()
        try await rig.queue.register(handler: FakeJobHandler(type: .transcribe))
        rig.catalog.setMissingModels(
            [ModelDescriptor(
                id: "m", version: "1", role: .asr, engine: "e", runtime: .coreml, displayName: "M",
                description: "d", sizeBytes: 1, languages: [], files: [], quantization: nil,
                minChip: .m1, minRAMGB: 1, recommendedFor: []
            )], for: "p"
        )
        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()

        _ = try await rig.queue.submit(makeSubmission(
            payload: .transcribe(recordingId: UUID(), profileId: "p", language: nil),
            forbidWhileRecording: true, requiresProfileReady: "p"
        ))
        guard case .submitted = await iterator.next() else {
            return XCTFail("ожидался submitted")
        }

        await rig.queue.recordingDidStart()
        await rig.queue.start()
        guard case .blocked(_, _, let reason) = await iterator.next() else {
            return XCTFail("ожидался blocked")
        }
        XCTAssertEqual(reason, .recordingInProgress, "recordingInProgress раньше profileNotReady")
        XCTAssertEqual(rig.catalog.callCount, 0, "дорогой предикат не вычисляется — recordingInProgress раньше")
    }

    /// К57: предикат §1.1 тотален по исходу вызова; `nil` — без обращения к каталогу.
    /// Предел одновременных задач поднят намеренно: этот критерий не о `concurrencyLimit`
    /// (К77), и три задачи одного типа обязаны стартовать в одном пересмотре разом, не
    /// вытесняя друг друга через предел.
    func test_k57_profilePredicateIsTotalOverCatalogOutcome() async throws {
        let rig = JobQueueTestRig(globalConcurrencyLimit: 10, perTypeConcurrencyLimit: 10)
        let handler = FakeJobHandler(type: .transcribe)
        handler.workLong(seconds: 5)
        try await rig.queue.register(handler: handler)

        rig.catalog.setMissingModels([], for: "ready")
        let readyId = try await rig.queue.submit(makeSubmission(
            payload: .transcribe(recordingId: UUID(), profileId: "ready", language: nil),
            requiresProfileReady: "ready"
        ))

        let descriptor = ModelDescriptor(
            id: "m", version: "1", role: .asr, engine: "e", runtime: .coreml, displayName: "M",
            description: "d", sizeBytes: 1, languages: [], files: [], quantization: nil,
            minChip: .m1, minRAMGB: 1, recommendedFor: []
        )
        rig.catalog.setMissingModels([descriptor], for: "missing")
        let blockedId = try await rig.queue.submit(makeSubmission(
            payload: .transcribe(recordingId: UUID(), profileId: "missing", language: nil),
            requiresProfileReady: "missing"
        ))

        rig.catalog.setFailure(StubModelCatalogError.unknownProfile(id: "gone"), for: "gone")
        let unknownId = try await rig.queue.submit(makeSubmission(
            payload: .transcribe(recordingId: UUID(), profileId: "gone", language: nil),
            requiresProfileReady: "gone"
        ))

        let noProfileId = try await rig.queue.submit(makeSubmission(
            payload: .transcribe(recordingId: UUID(), profileId: "unused", language: nil),
            requiresProfileReady: nil
        ))

        let before = rig.catalog.callCount
        await rig.queue.start()

        let readyJob = try await rig.repository.job(id: readyId)
        XCTAssertEqual(readyJob?.status, .running, "пустой массив — выполнено")

        let blockedJob = try await rig.repository.job(id: blockedId)
        XCTAssertEqual(blockedJob?.status, .pending, "непустой массив — не выполнено")
        XCTAssertEqual(blockedJob?.attempts, 0)

        let unknownJob = try await rig.repository.job(id: unknownId)
        XCTAssertEqual(unknownJob?.status, .running, "unknownProfile — любой отказ означает «выполнено»")

        XCTAssertGreaterThan(rig.catalog.callCount, before, "каталог был опрошен трижды (ready/missing/gone)")

        let noProfileJob = try await rig.repository.job(id: noProfileId)
        XCTAssertNotEqual(noProfileJob?.status, .pending, "requiresProfileReady == nil не требует каталога")
    }

    /// К58: дорогой предикат не вычисляется, если условие раньше не пройдено; не чаще
    /// одного вызова на различный `profileId` за пересмотр.
    func test_k58_profileCatalogCalledAtMostOncePerDistinctProfileIdPerRevisit() async throws {
        // (i) невыполненный requiresACPower — каталог не опрашивается вовсе.
        do {
            let rig = JobQueueTestRig(powerSnapshot: PowerSnapshot(
                source: .battery, batteryFraction: 0.5, isLowPowerModeEnabled: false,
                thermalPressure: .nominal, checkedAt: Date(timeIntervalSince1970: 0)
            ))
            _ = try await rig.queue.submit(makeSubmission(requiresACPower: true, requiresProfileReady: "p1"))
            await rig.queue.start()
            XCTAssertEqual(rig.catalog.callCount, 0)
        }
        // (ii) два задания с ОДНИМ profileId в одном пересмотре — счётчик равен единице.
        do {
            let rig = JobQueueTestRig()
            _ = try await rig.queue.submit(makeSubmission(
                payload: .transcribe(recordingId: UUID(), profileId: "same", language: nil),
                requiresProfileReady: "same"
            ))
            _ = try await rig.queue.submit(makeSubmission(
                payload: .diarize(recordingId: UUID(), profileId: "same"), requiresProfileReady: "same"
            ))
            await rig.queue.start()
            XCTAssertEqual(rig.catalog.callCount, 1)
        }
        // (iii) два задания с РАЗНЫМИ profileId — счётчик равен двум.
        do {
            let rig = JobQueueTestRig()
            _ = try await rig.queue.submit(makeSubmission(
                payload: .transcribe(recordingId: UUID(), profileId: "a", language: nil), requiresProfileReady: "a"
            ))
            _ = try await rig.queue.submit(makeSubmission(
                payload: .diarize(recordingId: UUID(), profileId: "b"), requiresProfileReady: "b"
            ))
            await rig.queue.start()
            XCTAssertEqual(rig.catalog.callCount, 2)
        }
    }
}
