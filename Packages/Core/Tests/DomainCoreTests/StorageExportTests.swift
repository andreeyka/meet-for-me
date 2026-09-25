//  StorageExportTests — К41 (группа П плана MEE-410, перечень MEE-401, C-016 v10, MEE-441),
//  инв. 17.
//
//  `export` — инв. 17 дословно и целиком, содержимое файла не предмет критерия (см.
//  докстринг `AppFacadeImpl+StorageExport.swift`) — тесты ниже проверяют только то, что К41
//  называет: расположение внутри `directory`, отсутствие изменений за её пределами,
//  возвращённый `URL` указывает на созданное. `deleteRecording`/`deleteMeeting` — «без
//  дополнительной логики: счётчик обращений к репозиторию — ровно один на вызов».

import XCTest
@testable import DomainCore
import DomainTestKit

final class StorageExportTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            clock: { Date() }
        )
        return Fixture(facade: facade, repositories: repositories)
    }

    private func event(id: UUID, title: String) throws -> MeetingEvent {
        try MeetingEvent(
            id: id, sourceConnectorId: "eventkit", externalId: "evt-\(id.uuidString.prefix(8))", icalUid: nil,
            title: title, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1_800),
            timeZone: "UTC", isAllDay: false, isCancelled: false, organizer: nil, attendees: [], location: nil,
            bodyText: nil, conference: nil, lastModified: Date(timeIntervalSince1970: 0)
        )
    }

    // MARK: - К41: export — инв. 17

    /// Файл создан внутри `directory`, ни один файл вне неё не тронут; `URL` указывает на
    /// созданное.
    func test_k41_export_writesOnlyInsideRequestedDirectory() async throws {
        let fixture = makeFixture()
        let meetingId = UUID()
        fixture.repositories.meetings.seed([
            MeetingRecord(event: try event(id: meetingId, title: "Созвон"), dedupKey: nil, status: .ready, sources: [])
        ])
        let layout = TemporaryFileLayout()
        let directory = layout.layout.root.appendingPathComponent("export-target", isDirectory: true)
        let sentinel = layout.layout.root.appendingPathComponent("must-not-change.txt")
        try Data("до экспорта".utf8).write(to: sentinel)

        let url = try await fixture.facade.export(meetingId: meetingId, format: .markdown, to: directory)

        XCTAssertTrue(url.path.hasPrefix(directory.path), "\(url.path) должен лежать внутри \(directory.path)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(
            try Data(contentsOf: sentinel), Data("до экспорта".utf8), "вне directory ничего не изменилось"
        )
    }

    /// Несуществующая встреча — отказ, никакой файл не создан.
    func test_k41_export_unknownMeetingThrowsAndCreatesNothing() async throws {
        let fixture = makeFixture()
        let layout = TemporaryFileLayout()
        let directory = layout.layout.root.appendingPathComponent("export-target", isDirectory: true)

        do {
            _ = try await fixture.facade.export(meetingId: UUID(), format: .json, to: directory)
            XCTFail("ожидался отказ")
        } catch AppFacadeError.notFound(let entity, _) {
            XCTAssertEqual(entity, "Meeting")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    // MARK: - К41: deleteRecording/deleteMeeting — ровно один вызов, без доп. логики

    func test_k41_deleteRecording_callsRepositoryExactlyOnce() async throws {
        let fixture = makeFixture()
        let recordingId = UUID()
        fixture.repositories.recordings.seed([RecordingRecord(
            manifest: try RecordingManifest(
                recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
                startedAt: Date(timeIntervalSince1970: 0), endedAt: nil,
                tracks: [
                    try RecordingManifest.Track(
                        channel: .mic, fileName: "audio-mic.m4a", sampleRate: 16_000, channelCount: 1,
                        format: "aac-m4a"
                    )
                ],
                markers: [], capturedProcesses: [], captureGroupKey: nil, inputDevices: [], discontinuities: [],
                isFinalized: true
            ),
            status: .finalized
        )])

        try await fixture.facade.deleteRecording(recordingId: recordingId, deleteFiles: true)

        XCTAssertEqual(
            fixture.repositories.log.count(port: "RecordingRepository", method: "delete(recordingId:deleteFiles:)"), 1
        )
        let remaining = try await fixture.repositories.recordings.recording(id: recordingId)
        XCTAssertNil(remaining)
    }

    func test_k41_deleteMeeting_callsRepositoryExactlyOnce() async throws {
        let fixture = makeFixture()
        let meetingId = UUID()
        fixture.repositories.meetings.seed([
            MeetingRecord(event: try event(id: meetingId, title: "Созвон"), dedupKey: nil, status: .ready, sources: [])
        ])

        try await fixture.facade.deleteMeeting(meetingId: meetingId)

        XCTAssertEqual(fixture.repositories.log.count(port: "MeetingRepository", method: "delete(meetingIds:)"), 1)
        let remaining = try await fixture.repositories.meetings.meeting(id: meetingId)
        XCTAssertNil(remaining)
    }
}
