//  AppFacadeImplReadModelsTests — добор К4 по сверке покрытия MEE-401 (`484179e8`), MEE-448:
//  повторное чтение без побочных эффектов для ВСЕХ реализованных методов чтения, не только
//  `meetings` (он — в `AppFacadeImplReadModelsTests.swift`). Тот же класс, `epoch`/`event`/
//  `segment`/`manifest` — оттуда.
//
//  Вне теста — три метода чтения К4, которые сегодня бросают `notImplemented`:
//  `meeting(id:)`, `search(query:limit:offset:)`, `jobs(status:)` (`AppFacadeImpl+Reads.swift`).
//  Их повторное чтение проверять не на чем, это не заявляется.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension AppFacadeImplReadModelsTests {

    /// Все реализованные чтения К4 одним снимком. `meetings` включён ради `status()`,
    /// который строит `upcoming` из тех же встреч.
    private struct ReadRound: Equatable {
        let status: AppStatus
        let meetings: [MeetingListItem]
        let transcript: TranscriptView?
        let latestTranscript: TranscriptView?
        let permissions: PermissionSnapshot
        let models: [ModelDescriptor]
        let modelState: ModelState
        let profiles: [TranscriptionProfile]
        let settings: AppSettings
    }

    private func readAll(_ facade: AppFacadeImpl, transcriptId: UUID, recordingId: UUID) async throws -> ReadRound {
        ReadRound(
            status: await facade.status(),
            meetings: try await facade.meetings(
                from: epoch.addingTimeInterval(-86_400), to: epoch.addingTimeInterval(86_400)
            ),
            transcript: try await facade.transcript(id: transcriptId),
            latestTranscript: try await facade.latestTranscript(recordingId: recordingId),
            permissions: await facade.permissions(),
            models: await facade.models(),
            modelState: await facade.modelState(id: "asr-a", version: "1.0.0"),
            profiles: await facade.profiles(),
            settings: try await facade.settings()
        )
    }

    // MARK: - К4 (инв. 3, 20): каждое реализованное чтение идемпотентно на неизменном состоянии

    /// Состояние каждого фейка непусто и не равно умолчаниям — иначе равенство двух пустых
    /// ответов ничего бы не значило. Побочный эффект, видимый снаружи, — событие фасада:
    /// подписка открыта до чтений, и за оба прохода не должно прийти ни одного.
    func test_k04_readMethodsIdempotentAndAllAsync() async throws {
        let repositories = InMemoryRepositories()
        let catalog = FakeModelCatalogPort()
        catalog.setCatalog([descriptor(id: "asr-a", version: "1.0.0", sizeBytes: 1_000_000)])
        catalog.setState(.paused(bytesOnDisk: 4_321), forId: "asr-a", version: "1.0.0")
        catalog.setProfiles([profile(id: "profile-a", asrModelId: "asr-a")])
        let clock = ManualClock(now: epoch)
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: epoch),
            modelCatalog: catalog,
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            jobQueue: FakeJobQueue(),
            fileLayout: FileLayout(root: FileManager.default.temporaryDirectory),
            clock: { clock.now() }
        )

        let planned = try event(id: UUID(), start: epoch.addingTimeInterval(3_600), title: "Планёрка")
        repositories.meetings.seed([MeetingRecord(event: planned, dedupKey: nil, status: .scheduled, sources: [])])
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let speaker = try Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 1_000)
        let header = try await repositories.transcripts.save(try Transcript(
            recordingId: recordingId, language: "ru", engine: "e", modelVersion: "1", createdAt: epoch,
            segments: [try segment(startMs: 0, endMs: 1_000, cluster: 0, text: "текст")], speakers: [speaker]
        ))
        try await repositories.settings.setValue(try DomainJSON.encode(true), forKey: "voiceProfilesEnabled")
        let stream = facade.events()

        let first = try await readAll(facade, transcriptId: header.id, recordingId: recordingId)
        let second = try await readAll(facade, transcriptId: header.id, recordingId: recordingId)

        XCTAssertEqual(first, second, "повторное чтение без команд между вызовами равно")
        XCTAssertNotNil(first.transcript)
        XCTAssertNotNil(first.latestTranscript)
        XCTAssertEqual(first.meetings.count, 1)
        XCTAssertEqual(first.models.count, 1)
        XCTAssertEqual(first.modelState, .paused(bytesOnDisk: 4_321))
        XCTAssertEqual(first.profiles.map(\.id), ["profile-a"])
        XCTAssertTrue(first.settings.voiceProfilesEnabled)
        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)
        XCTAssertTrue(events.isEmpty, "чтение не публикует событий: \(events)")
    }
}
