//  MeetingDetailTests — `meeting(id:)` (C-016 v11 §1, §4; IR-142 п. 1–2, MEE-455; задачи MEE-449,
//  MEE-462): вторая половина К42 (`RecordingSummary.capturedProcesses` — поле манифеста без
//  изменения) и сборка `MeetingDetail` из репозиториев C-010 v27.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class MeetingDetailTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/mee462-layout", isDirectory: true)

    private func makeFacade(_ repositories: InMemoryRepositories) -> AppFacadeImpl {
        AppFacadeImpl(
            meetings: repositories.meetings, recordings: repositories.recordings,
            transcripts: repositories.transcripts, persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: FakeModelCatalogPort(), calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(), attribution: FakeAttributionPort(),
            settings: repositories.settings, connectors: repositories.connectors,
            jobQueue: FakeJobQueue(), fileLayout: FileLayout(root: root)
        )
    }

    /// Манифест фикстуры, перепривязанный к встрече, — `recordings(meetingId:)` находит запись по нему.
    private func manifest(_ base: RecordingManifest, meetingId: UUID) throws -> RecordingManifest {
        try RecordingManifest(
            recordingId: base.recordingId, meetingId: meetingId, directoryName: base.directoryName,
            startedAt: base.startedAt, endedAt: base.endedAt, tracks: base.tracks, markers: base.markers,
            capturedProcesses: base.capturedProcesses, captureGroupKey: base.captureGroupKey,
            inputDevices: base.inputDevices, discontinuities: base.discontinuities, isFinalized: base.isFinalized
        )
    }

    // MARK: - К42, вторая половина (инв. 27)

    func test_k42_recordingSummaryCapturedProcessesEqualManifestUnion() async throws {
        let repositories = InMemoryRepositories()
        let event = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: []))
        let recorded = try manifest(RecordingManifestFixtures.hourlyTwoChannels, meetingId: event.id)
        XCTAssertFalse(recorded.capturedProcesses.isEmpty, "иначе равенство вакуумно")
        repositories.recordings.seed([RecordingRecord(manifest: recorded, status: .finalized)])

        let detail = try await makeFacade(repositories).meeting(id: event.id)

        let summary = try XCTUnwrap(detail?.recordings.first)
        XCTAssertEqual(summary.capturedProcesses, recorded.capturedProcesses, "поле манифеста без изменения")
    }

    // MARK: - Сборка MeetingDetail

    func test_meetingDetailAssembledFromRepositoriesAndFileLayout() async throws {
        let repositories = InMemoryRepositories()
        let event = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: []))
        let recorded = try manifest(RecordingManifestFixtures.hourlyTwoChannels, meetingId: event.id)
        repositories.recordings.seed([RecordingRecord(manifest: recorded, status: .finalized)])
        let facade = makeFacade(repositories)

        let fetched = try await facade.meeting(id: event.id)
        let detail = try XCTUnwrap(fetched)

        let meetingRecord = try await repositories.meetings.meeting(id: event.id)
        let attendees = try await repositories.persons.attendees(meetingId: event.id)
        let organizer = try await repositories.persons.organizer(meetingId: event.id)
        XCTAssertEqual(detail.meeting, meetingRecord)
        XCTAssertFalse(attendees.isEmpty, "иначе равенство вакуумно")
        XCTAssertEqual(detail.attendees, attendees, "PersonRepository.attendees без пересборки")
        XCTAssertEqual(detail.organizer, organizer)
        XCTAssertEqual(detail.outputs, [], "в Срезе 1 всегда пуст")

        let summary = try XCTUnwrap(detail.recordings.first)
        XCTAssertEqual(detail.recordings.count, 1)
        XCTAssertEqual(summary.recordingId, recorded.recordingId)
        XCTAssertEqual(summary.startedAt, recorded.startedAt)
        XCTAssertEqual(summary.endedAt, recorded.endedAt)
        XCTAssertEqual(summary.status, .finalized)
        XCTAssertEqual(summary.markers, recorded.markers)
        let headers = try await repositories.transcripts.headers(recordingId: recorded.recordingId)
        XCTAssertEqual(summary.transcripts, headers)
        let directory = FileLayout(root: root).recordingDirectory(recorded.directoryName)
        XCTAssertEqual(summary.tracks.map(\.channel), recorded.tracks.map(\.channel))
        XCTAssertEqual(summary.tracks.map(\.fileURL),
                       recorded.tracks.map { directory.appendingPathComponent($0.fileName) })
    }

    func test_meetingOfUnknownIdIsNil() async throws {
        let detail = try await makeFacade(InMemoryRepositories()).meeting(id: UUID())
        XCTAssertNil(detail)
    }

    /// Инв. 19: отказ хранилища — `.underlying` с кодом `storage.*`.
    func test_meetingStorageFailureSurfacesAsStorageCode() async throws {
        let repositories = InMemoryRepositories()
        let event = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: []))
        repositories.persons.fail(with: .io(message: "диск"), on: .attendees)

        do {
            _ = try await makeFacade(repositories).meeting(id: event.id)
            XCTFail("отказ репозитория обязан дойти до вызывающего")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "storage.io")
        }
    }
}
