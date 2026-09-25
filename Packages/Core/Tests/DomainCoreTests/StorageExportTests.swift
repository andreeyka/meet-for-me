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
    /// созданное. Возврат РП (приёмка 12:00 UTC, «мелочи»): `hasPrefix` без завершающего `/`
    /// пропускал бы соседний каталог с тем же началом имени (`export-target-evil` матчился
    /// бы префиксом `export-target`) — сверяется точным равенством ИЛИ префиксом с `/`, и
    /// целиком снимком временной ФС до/после (не одним файлом-часовым), тем же приёмом, что
    /// критерий и называет («снимок файловой системы до/после»).
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
        let before = try outsideSnapshot(root: layout.layout.root, excluding: directory)

        let url = try await fixture.facade.export(meetingId: meetingId, format: .markdown, to: directory)

        XCTAssertTrue(
            url.path == directory.path || url.path.hasPrefix(directory.path + "/"),
            "\(url.path) должен лежать внутри \(directory.path)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let after = try outsideSnapshot(root: layout.layout.root, excluding: directory)
        XCTAssertEqual(before, after, "вне directory ничего не изменилось")
    }

    /// Снимок всех файлов внутри `root`, кроме поддерева `directory`, — имя файла (путь
    /// относительно `root`) → содержимое. Каталоги в снимок не входят: сравнение по
    /// содержимому файлов достаточно и не завязано на порядок обхода.
    private func outsideSnapshot(root: URL, excluding directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let excludedPrefix = directory.path + "/"
        for relative in try FileManager.default.subpathsOfDirectory(atPath: root.path) {
            let full = root.appendingPathComponent(relative)
            if full.path == directory.path || full.path.hasPrefix(excludedPrefix) { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory) else { continue }
            guard !isDirectory.boolValue else { continue }
            result[relative] = try Data(contentsOf: full)
        }
        return result
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

    /// Возврат РП (приёмка 12:00 UTC, находка 2): «сейчас подделка „событие не
    /// публикуется“ проходит» — тест теперь подписывается на `events()` до вызова и требует
    /// хотя бы одно событие (инв. 15), не только счётчик обращений к репозиторию.
    func test_k41_deleteRecording_callsRepositoryExactlyOnceAndPublishesEvent() async throws {
        let fixture = makeFixture()
        let recordingId = UUID()
        fixture.repositories.recordings.seed([RecordingRecord(
            manifest: try RecordingManifest(
                recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
                startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 600),
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
        let stream = fixture.facade.events()

        try await fixture.facade.deleteRecording(recordingId: recordingId, deleteFiles: true)

        XCTAssertEqual(
            fixture.repositories.log.count(port: "RecordingRepository", method: "delete(recordingId:deleteFiles:)"), 1
        )
        let remaining = try await fixture.repositories.recordings.recording(id: recordingId)
        XCTAssertNil(remaining)
        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 1, "\(events)")
    }

    /// Симметрично `deleteRecording` выше — событие проверяется, не только счётчик.
    func test_k41_deleteMeeting_callsRepositoryExactlyOnceAndPublishesEvent() async throws {
        let fixture = makeFixture()
        let meetingId = UUID()
        fixture.repositories.meetings.seed([
            MeetingRecord(event: try event(id: meetingId, title: "Созвон"), dedupKey: nil, status: .ready, sources: [])
        ])
        let stream = fixture.facade.events()

        try await fixture.facade.deleteMeeting(meetingId: meetingId)

        XCTAssertEqual(fixture.repositories.log.count(port: "MeetingRepository", method: "delete(meetingIds:)"), 1)
        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 1, "\(events)")
        let remaining = try await fixture.repositories.meetings.meeting(id: meetingId)
        XCTAssertNil(remaining)
    }
}
