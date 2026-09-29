//  JobCommandsTests — план MEE-410, группа Н (К37, К38 перечня MEE-401; C-016 v10 инв. 12,
//  «Что вне контракта»; задача MEE-420). Предмет — `AppFacadeImpl` на `FakeModelCatalogPort`
//  и `FakeJobQueue`; координатор — `NoOpSessionCoordinator` этого таргета (страж К88).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

/// Фикстура групп М/Н: фасад с фейками каталога и очереди. Общая для `JobCommandsTests`,
/// `ModelsAndProfilesTests+Commands`, `ErrorDictionaryModelsJobsTests`, `EventsTests+Models`.
struct ModelJobFixture {
    let facade: AppFacadeImpl
    let catalog: FakeModelCatalogPort
    let queue: FakeJobQueue
    let repositories: InMemoryRepositories

    init(withQueue: Bool = true) {
        let repositories = InMemoryRepositories()
        let catalog = FakeModelCatalogPort()
        let queue = FakeJobQueue()
        self.repositories = repositories
        self.catalog = catalog
        self.queue = queue
        self.facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: catalog,
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            jobQueue: withQueue ? queue : nil,
            clock: { Date() }
        )
    }

    static func descriptor(_ id: String, role: ModelRole) -> ModelDescriptor {
        ModelDescriptor(
            id: id, version: "1.0.0", role: role, engine: "sherpaonnx", runtime: .onnx,
            displayName: id, description: id, sizeBytes: 10, languages: [],
            files: [ModelFile(name: "\(id).bin", url: URL(fileURLWithPath: "/\(id)"),
                              sha256: String(repeating: "0", count: 64), sizeBytes: 10)],
            quantization: nil, minChip: .m1, minRAMGB: 1, recommendedFor: []
        )
    }

    static func profile(_ id: String, asr: String, vad: String? = nil, builtIn: Bool = false) -> TranscriptionProfile {
        TranscriptionProfile(
            id: id, displayName: id, language: "ru", asrModelId: asr, vadModelId: vad,
            diarizationModelId: nil, embeddingModelId: nil,
            diarization: DiarizationParameters(expectedSpeakers: nil, clusteringThreshold: 0.7, minSegmentMs: 500),
            isBuiltIn: builtIn
        )
    }

    static func failedJob(id: UUID = UUID()) -> Job {
        let epoch = Date(timeIntervalSince1970: 0)
        return Job(
            id: id, type: .transcribe,
            payload: .transcribe(recordingId: UUID(), profileId: "p1", language: nil),
            status: .failed, priority: 30, attempts: 3, maxAttempts: 3, runAfter: epoch,
            conditions: JobConditions(requiresACPower: false, forbidWhileRecording: true,
                                      maxThermalPressure: .fair, requiresProfileReady: "p1"),
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil,
            lastError: "engine.serviceCrashed", createdAt: epoch, updatedAt: epoch
        )
    }
}

/// Отказ команды фасада как `AppErrorView` (`underlying`); иной исход — провал теста.
func underlyingView(file: StaticString = #filePath, line: UInt = #line,
                    _ body: () async throws -> Void) async -> AppErrorView? {
    do {
        try await body()
        XCTFail("ожидался отказ", file: file, line: line)
    } catch AppFacadeError.underlying(let view) {
        return view
    } catch {
        XCTFail("ожидался AppFacadeError.underlying, получено \(error)", file: file, line: line)
    }
    return nil
}

final class JobCommandsTests: XCTestCase {

    /// Профиль `p1`: asr скачан, vad — нет.
    private func seedProfileMissingVad(_ fixture: ModelJobFixture) {
        fixture.catalog.setCatalog([
            ModelJobFixture.descriptor("m-asr", role: .asr), ModelJobFixture.descriptor("m-vad", role: .vad)
        ])
        fixture.catalog.setState(.downloaded, forId: "m-asr", version: "1.0.0")
        fixture.catalog.setState(.available, forId: "m-vad", version: "1.0.0")
        fixture.catalog.setProfiles([ModelJobFixture.profile("p1", asr: "m-asr", vad: "m-vad")])
    }

    /// Профиль `p1`: все модели скачаны — `retranscribe` ставит задачу.
    private func seedProfileReady(_ fixture: ModelJobFixture) {
        seedProfileMissingVad(fixture)
        fixture.catalog.setState(.downloaded, forId: "m-vad", version: "1.0.0")
    }

    /// Действующие настройки: срез-1 по умолчанию с заданным «обрабатывать только от сети».
    private func setProcessOnACPowerOnly(_ value: Bool, in fixture: ModelJobFixture) async throws {
        let defaults = AppSettings.slice1Defaults
        try await fixture.facade.updateSettings(AppSettings(
            recordingPolicy: defaults.recordingPolicy, armLeadSeconds: defaults.armLeadSeconds,
            askLeadSeconds: defaults.askLeadSeconds, missingSignalGraceSeconds: defaults.missingSignalGraceSeconds,
            silenceStopSeconds: defaults.silenceStopSeconds, defaultProfileId: defaults.defaultProfileId,
            processOnACPowerOnly: value, processWhileRecording: defaults.processWhileRecording,
            audioRetentionDays: defaults.audioRetentionDays, voiceProfilesEnabled: defaults.voiceProfilesEnabled,
            notifyParticipants: defaults.notifyParticipants, launchAtLogin: defaults.launchAtLogin
        ))
    }

    // MARK: - К37 (инв. 12)

    func test_k37_retranscribeMissingModelsThrowsProfileNotReady() async throws {
        let fixture = ModelJobFixture()
        seedProfileMissingVad(fixture)
        let recordingId = UUID()
        do {
            _ = try await fixture.facade.retranscribe(recordingId: recordingId, profileId: "p1")
            XCTFail("ожидался profileNotReady")
        } catch let error as AppFacadeError {
            XCTAssertEqual(error, .profileNotReady(profileId: "p1", missingModelIds: ["m-vad"]))
        }
        XCTAssertTrue(fixture.queue.submissions.isEmpty, "задача не ставится")
        XCTAssertEqual(fixture.queue.callLog.calls(port: FakeJobQueue.portName).count, 0,
                       "к очереди — ни одного обращения")

        // Вектор непустоты: модели готовы — задача ставится, `jobId` — ответ очереди.
        fixture.catalog.setState(.downloaded, forId: "m-vad", version: "1.0.0")
        let jobId = try await fixture.facade.retranscribe(recordingId: recordingId, profileId: "p1")
        XCTAssertEqual(jobId, FakeJobQueue.deterministicId(1))
        XCTAssertEqual(fixture.queue.submissions.map(\.payload),
                       [.transcribe(recordingId: recordingId, profileId: "p1", language: nil)])
        XCTAssertEqual(fixture.queue.submissions.first?.conditions.requiresProfileReady, "p1")
    }

    // MARK: - К38 («Команды обработки», «Что вне контракта»)

    func test_k38_cancelAndRetryJobBehaviorPerContract() async throws {
        let fixture = ModelJobFixture()
        let existing = ModelJobFixture.failedJob()
        fixture.queue.setJobs([existing])

        try await fixture.facade.cancelJob(id: existing.id)
        XCTAssertEqual(fixture.queue.cancellations, [existing.id])
        XCTAssertEqual(fixture.queue.callLog.count(port: FakeJobQueue.portName, method: "cancel(jobId:)"), 1,
                       "cancelJob — ровно одно обращение к очереди")

        let unknown = UUID()
        fixture.queue.failCancel(with: .unknownJob(unknown))
        let view = await underlyingView { try await fixture.facade.cancelJob(id: unknown) }
        XCTAssertEqual(view?.code, "jobs.unknownJob")
        XCTAssertEqual(fixture.queue.cancellations, [existing.id], "отказавшая отмена состояния не меняет")
        let failed = try await fixture.facade.jobs(status: .failed)
        XCTAssertEqual(failed, [existing], "задача в очереди не изменилась")

        let retried = try await fixture.facade.retryJob(id: existing.id)
        XCTAssertNotEqual(retried, existing.id, "retryJob — новый jobId")
        XCTAssertEqual(fixture.queue.submissions.last?.payload, existing.payload, "та же нагрузка")
    }

    func test_retryJobOfUnknownJobThrowsJobsUnknownJobAndSubmitsNothing() async throws {
        let fixture = ModelJobFixture()
        let view = await underlyingView { _ = try await fixture.facade.retryJob(id: UUID()) }
        XCTAssertEqual(view?.code, "jobs.unknownJob")
        XCTAssertTrue(fixture.queue.submissions.isEmpty)
    }

    /// Правило §4 C-013 «только от сети» (MEE-464): `retranscribe` при `processOnACPowerOnly ==
    /// true` ставит задачу с `requiresACPower == true`, при `false` — подача равна `standard`.
    func test_retranscribeAppliesProcessOnACPowerOnlyRule() async throws {
        for (acOnly, expected) in [(true, true), (false, false)] {
            let fixture = ModelJobFixture()
            seedProfileReady(fixture)
            try await setProcessOnACPowerOnly(acOnly, in: fixture)
            let recordingId = UUID()
            _ = try await fixture.facade.retranscribe(recordingId: recordingId, profileId: "p1")
            let submission = try XCTUnwrap(fixture.queue.submissions.first, "processOnACPowerOnly=\(acOnly)")
            XCTAssertEqual(submission.conditions.requiresACPower, expected, "processOnACPowerOnly=\(acOnly)")
            let standard = JobSubmission.standard(
                .transcribe(recordingId: recordingId, profileId: "p1", language: nil), runAfter: submission.runAfter
            )
            XCTAssertFalse(standard.conditions.requiresACPower, "вектор непустоты: у transcribe таблица даёт false")
            XCTAssertEqual(submission.conditions.forbidWhileRecording, standard.conditions.forbidWhileRecording)
            XCTAssertEqual(submission.conditions.maxThermalPressure, standard.conditions.maxThermalPressure)
            XCTAssertEqual(submission.conditions.requiresProfileReady, standard.conditions.requiresProfileReady)
            XCTAssertEqual(submission.priority, standard.priority)
            XCTAssertEqual(submission.maxAttempts, standard.maxAttempts)
        }
    }

    /// Без очереди каждая команда группы Н отказывает `notAllowed` — и чтение, и три команды.
    func test_groupNWithoutJobQueueThrowsNotAllowed() async throws {
        let fixture = ModelJobFixture(withQueue: false)
        let commands: [(String, () async throws -> Void)] = [
            ("retranscribe", { _ = try await fixture.facade.retranscribe(recordingId: UUID(), profileId: "p1") }),
            ("cancelJob", { try await fixture.facade.cancelJob(id: UUID()) }),
            ("retryJob", { _ = try await fixture.facade.retryJob(id: UUID()) }),
            ("jobs(status:)", { _ = try await fixture.facade.jobs(status: .failed) })
        ]
        for (name, command) in commands {
            do {
                try await command()
                XCTFail("\(name): без очереди — отказ")
            } catch AppFacadeError.notAllowed {
            } catch {
                XCTFail("\(name): ожидался notAllowed, получено \(error)")
            }
        }
    }

    /// Инв. 15: команда, изменившая очередь, публикует `statusChanged` до возврата.
    func test_jobCommandsPublishStatusChanged() async throws {
        let fixture = ModelJobFixture()
        seedProfileReady(fixture)
        let existing = ModelJobFixture.failedJob()
        fixture.queue.setJobs([existing])
        let stream = fixture.facade.events()
        _ = try await fixture.facade.retranscribe(recordingId: UUID(), profileId: "p1")
        try await fixture.facade.cancelJob(id: existing.id)
        _ = try await fixture.facade.retryJob(id: existing.id)
        let events = await collectEvents(stream, count: 3)
        XCTAssertEqual(events.count, 3)
        for event in events {
            guard case .statusChanged = event else { return XCTFail("ожидался .statusChanged, получено \(event)") }
        }
    }
}
