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

    /// К53 (i): status != .pending — cancelled её исключает.
    ///
    /// Усиление по возврату РП (MEE-350): `runCallCount == 0` сразу после `start()`, без
    /// `waitUntilIdle()`, верно и на неверной реализации — исполнение идёт отдельной `Task`
    /// (§7), которую пересмотр не ждёт, и счётчик мог ещё просто не успеть увеличиться к
    /// моменту проверки. `waitUntilIdle()` даёт фоновой `Task`, если реализация ошибочно её
    /// всё же завела, шанс дойти до `handler.run()`; статус `cancelled` — вторым, независимым
    /// от счётчика, признаком, что строка вообще не была тронута пересмотром.
    func test_k53a_cancelledStatusExcludesReadiness() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        try await rig.queue.register(handler: handler)
        let id = try await rig.queue.submit(makeSubmission())
        try await rig.queue.cancel(jobId: id)
        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        XCTAssertEqual(handler.runCallCount, 0, "cancelled задача не исполняется")
        let job = try await rig.repository.job(id: id)
        XCTAssertEqual(job?.status, .cancelled, "статус не тронут пересмотром")
    }

    /// К53 (ii): runAfter > now.
    ///
    /// Тот же фикс, что К53а: `waitUntilIdle()` до счётчика, статус `.pending` как второй,
    /// независимый признак — иначе тест проходит и на реализации, которая по ошибке всё же
    /// стартовала бы задачу (см. комментарий у К53а).
    func test_k53b_runAfterInTheFutureExcludesReadiness() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        try await rig.queue.register(handler: handler)
        let id = try await rig.queue.submit(makeSubmission(runAfter: rig.clock.now().addingTimeInterval(3_600)))
        await rig.queue.start()
        await rig.queue.waitUntilIdle()
        XCTAssertEqual(handler.runCallCount, 0)
        let job = try await rig.repository.job(id: id)
        XCTAssertEqual(job?.status, .pending, "статус не тронут пересмотром")
    }

    /// К53 (iii): обработчик типа не зарегистрирован.
    func test_k53c_missingHandlerExcludesReadiness() async throws {
        let rig = JobQueueTestRig()
        let id = try await rig.queue.submit(makeSubmission())
        await rig.queue.start()
        let job = try await rig.repository.job(id: id)
        XCTAssertEqual(job?.status, .pending)
    }

    /// К53 (iv): превышен maxConcurrent ТИПА — два transcode при пределе типа 1.
    func test_k53d_perTypeConcurrencyLimitExcludesReadiness() async throws {
        let rig = JobQueueTestRig(globalConcurrencyLimit: 2, perTypeConcurrencyLimit: 1)
        let handler = FakeJobHandler(type: .transcode)
        handler.workLong(seconds: 0.3)
        try await rig.queue.register(handler: handler)
        _ = try await rig.queue.submit(makeSubmission(priority: 10))
        let secondId = try await rig.queue.submit(makeSubmission(priority: 5))
        await rig.queue.start()
        let second = try await rig.repository.job(id: secondId)
        XCTAssertEqual(second?.status, .pending, "предел типа 1 уже занят первой задачей")
    }

    /// К53 (v): превышен ГЛОБАЛЬНЫЙ предел — разные типы, предел 1.
    func test_k53e_globalConcurrencyLimitExcludesReadiness() async throws {
        let rig = JobQueueTestRig(globalConcurrencyLimit: 1, perTypeConcurrencyLimit: 1)
        let transcodeHandler = FakeJobHandler(type: .transcode)
        transcodeHandler.workLong(seconds: 0.3)
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

    /// К53 (vi): одно из четырёх условий JobConditions не выполнено — requiresACPower на battery.
    func test_k53f_unmetJobConditionExcludesReadiness() async throws {
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

    /// К53 (vii): седьмой вход — все шесть клауз выполнены — исполняется.
    func test_k53g_allSixClausesSatisfiedIsReady() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        handler.workLong(seconds: 0.3)
        try await rig.queue.register(handler: handler)
        let id = try await rig.queue.submit(makeSubmission())
        await rig.queue.start()
        let job = try await rig.repository.job(id: id)
        XCTAssertEqual(job?.status, .running)
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
        handler.workLong(seconds: 0.3)
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
    ///
    /// СНЯТО XCTSkip по возврату РП (MEE-350): `runAfter <= now` в `InMemoryJobRepository
    /// .claimNext` возвращён (C-010 инвариант 25, «фильтрует по `status`, `run_after` и
    /// `type`»), и строка, не дошедшая по сроку, больше никогда не доходит до
    /// `firstBlockingReason` — `notYetDue` этим способом И недостижим. Противоречие с
    /// C-013 (инвариант 4 называет `notYetDue` случаем, который решает ОЧЕРЕДЬ) открыто
    /// архитектору как IR-121 (MEE-356); до его ответа этот вход не проверяем.
    func test_k56_notYetDueWinsOverWaitingForACPower() async throws {
        throw XCTSkip("IR-121: notYetDue недостижим при фильтре run_after, C-010 инв. 25")
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
        // Ровно один blocked: единственный кандидат, единственный пересмотр (recordingDidStart
        // до start() — isRunning ещё false, второго пересмотра не запускает) — claimNext звана
        // дважды: один раз кандидата взяла, второй раз отдала nil, чем пересмотр и завершился.
        XCTAssertEqual(rig.repository.claimNextCallCount, 2, "один кандидат и завершающий nil — не больше")
    }

    /// К57: предикат §1.1 тотален по исходу вызова; `nil` — без обращения к каталогу.
    /// Предел одновременных задач поднят намеренно: этот критерий не о `concurrencyLimit`
    /// (К77), и три задачи одного типа обязаны стартовать в одном пересмотре разом, не
    /// вытесняя друг друга через предел.
    func test_k57_profilePredicateIsTotalOverCatalogOutcome() async throws {
        let rig = JobQueueTestRig(globalConcurrencyLimit: 10, perTypeConcurrencyLimit: 10)
        let handler = FakeJobHandler(type: .transcribe)
        handler.workLong(seconds: 0.3)
        try await rig.queue.register(handler: handler)

        rig.catalog.setMissingModels([], for: "ready")
        let readyId = try await submitTranscribeReady(rig, profileId: "ready", requiresProfileReady: "ready")

        rig.catalog.setMissingModels([Self.missingDescriptor], for: "missing")
        let blockedId = try await submitTranscribeReady(rig, profileId: "missing", requiresProfileReady: "missing")

        rig.catalog.setFailure(StubModelCatalogError.unknownProfile(id: "gone"), for: "gone")
        let unknownId = try await submitTranscribeReady(rig, profileId: "gone", requiresProfileReady: "gone")

        // Усиление по возврату РП (MEE-350): «любой брошенный отказ каталога — выполнено»
        // (§1.1) — не только `unknownProfile`; второй, иначе устроенный случай отказа
        // (`.other`, не связанный с профилем вовсе) обязан вести к тому же исходу.
        rig.catalog.setFailure(StubModelCatalogError.other("сеть каталога недоступна"), for: "other-error")
        let otherErrorId = try await submitTranscribeReady(
            rig, profileId: "other-error", requiresProfileReady: "other-error"
        )

        let noProfileId = try await submitTranscribeReady(rig, profileId: "unused", requiresProfileReady: nil)

        let before = rig.catalog.callCount
        await rig.queue.start()

        let readyJob = try await rig.repository.job(id: readyId)
        XCTAssertEqual(readyJob?.status, .running, "пустой массив — выполнено")

        let blockedJob = try await rig.repository.job(id: blockedId)
        XCTAssertEqual(blockedJob?.status, .pending, "непустой массив — не выполнено")
        XCTAssertEqual(blockedJob?.attempts, 0)

        let unknownJob = try await rig.repository.job(id: unknownId)
        XCTAssertEqual(unknownJob?.status, .running, "unknownProfile — любой отказ означает «выполнено»")

        let otherErrorJob = try await rig.repository.job(id: otherErrorId)
        XCTAssertEqual(otherErrorJob?.status, .running, "иной случай отказа — тем же правилом, «выполнено»")

        // Усиление по возврату РП: не «хотя бы раз», а РОВНО столько различных `profileId`,
        // сколько их действительно требует каталога — ready/missing/gone/other-error — четыре,
        // не больше; `noProfileId` (условие `nil`) каталог не трогает вовсе — иначе тест
        // проходит и на реализации, которая ошибочно зовёт каталог лишний раз.
        XCTAssertEqual(rig.catalog.callCount - before, 4, "каталог опрошен четырежды — по числу профилей условия")

        let noProfileJob = try await rig.repository.job(id: noProfileId)
        XCTAssertNotEqual(noProfileJob?.status, .pending, "requiresProfileReady == nil не требует каталога")
    }

    /// Оснастка К57 — вынесена из тела теста, чтобы уложиться в `function_body_length`
    /// (50 строк): пять однотипных подач отличались только `profileId`.
    private func submitTranscribeReady(
        _ rig: JobQueueTestRig, profileId: String, requiresProfileReady: String?
    ) async throws -> UUID {
        try await rig.queue.submit(makeSubmission(
            payload: .transcribe(recordingId: UUID(), profileId: profileId, language: nil),
            requiresProfileReady: requiresProfileReady
        ))
    }

    private static let missingDescriptor = ModelDescriptor(
        id: "m", version: "1", role: .asr, engine: "e", runtime: .coreml, displayName: "M",
        description: "d", sizeBytes: 1, languages: [], files: [], quantization: nil,
        minChip: .m1, minRAMGB: 1, recommendedFor: []
    )

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
        // Обработчики обоих типов зарегистрированы — иначе `noHandler` отсекает условие
        // готовности профиля раньше, чем очередь дойдёт до каталога (порядок случаев
        // `JobBlockReason`), и счётчик остался бы нулём независимо от намерения теста.
        do {
            let rig = JobQueueTestRig()
            try await rig.queue.register(handler: FakeJobHandler(type: .transcribe))
            try await rig.queue.register(handler: FakeJobHandler(type: .diarize))
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
            try await rig.queue.register(handler: FakeJobHandler(type: .transcribe))
            try await rig.queue.register(handler: FakeJobHandler(type: .diarize))
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
