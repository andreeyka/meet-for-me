//  AdHocRecordingsTests — `adHocRecordings(from:to:)` (C-016 v12, инвариант 33; IR-146, MEE-482).
//
//  Фасад на прямых in-memory репозиториях: источник — `RecordingRepository.adHoc()`, модель —
//  `RecordingSummary`, собранная тем же кодом, что `MeetingDetail.recordings`.
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class AdHocRecordingsTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private let root = URL(fileURLWithPath: "/tmp/mee482-layout", isDirectory: true)

    private func makeFacade(_ repositories: InMemoryRepositories) -> AppFacadeImpl {
        AppFacadeImpl(
            meetings: repositories.meetings, recordings: repositories.recordings,
            transcripts: repositories.transcripts, persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: epoch),
            modelCatalog: FakeModelCatalogPort(), calendar: FakeCalendarPort(),
            sessionCoordinator: NoOpSessionCoordinator(), attribution: FakeAttributionPort(),
            settings: repositories.settings, connectors: repositories.connectors,
            jobQueue: FakeJobQueue(), fileLayout: FileLayout(root: root), clock: { [epoch] in epoch }
        )
    }

    private func manifest(
        id: UUID = UUID(), meetingId: UUID? = nil, start: TimeInterval, end: TimeInterval?
    ) throws -> RecordingManifest {
        try RecordingManifest(
            recordingId: id, meetingId: meetingId, directoryName: id.uuidString,
            startedAt: epoch.addingTimeInterval(start), endedAt: end.map { epoch.addingTimeInterval($0) },
            tracks: [
                try RecordingManifest.Track(
                    channel: .mic, fileName: "audio-mic.m4a", sampleRate: 16_000, channelCount: 1, format: "aac-m4a"
                )
            ],
            markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [], discontinuities: [], isFinalized: end != nil
        )
    }

    private func ids(_ summaries: [RecordingSummary]) -> [UUID] { summaries.map(\.recordingId) }

    private var wideWindow: (Date, Date) { (epoch.addingTimeInterval(-10_000), epoch.addingTimeInterval(10_000)) }

    // MARK: - Инв. 33: источник и статус

    /// `adHoc()` без фильтра по статусу: все четыре `RecordingStatus` присутствуют.
    func test_inv33_everyRecordingStatusIsReturned() async throws {
        let repositories = InMemoryRepositories()
        var expected: [UUID] = []
        for (index, status) in [RecordingStatus.recording, .stopping, .finalized, .failed].enumerated() {
            let recorded = try manifest(start: Double(index * 10), end: Double(index * 10 + 5))
            repositories.recordings.seed([RecordingRecord(manifest: recorded, status: status)])
            expected.append(recorded.recordingId)
        }

        let (from, to) = wideWindow
        let summaries = try await makeFacade(repositories).adHocRecordings(from: from, to: to)

        XCTAssertEqual(ids(summaries), expected)
        XCTAssertEqual(summaries.map(\.status), [.recording, .stopping, .finalized, .failed])
    }

    /// Запись, чью встречу удалили, присутствует; запись, привязанная к живой встрече, — нет.
    func test_inv33_recordingWhoseMeetingWasDeletedIsPresent() async throws {
        let repositories = InMemoryRepositories()
        let facade = makeFacade(repositories)
        let event = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: []))
        let orphaned = try manifest(meetingId: event.id, start: 0, end: 60)
        repositories.recordings.seed([RecordingRecord(manifest: orphaned, status: .finalized)])
        let (from, to) = wideWindow

        let before = try await facade.adHocRecordings(from: from, to: to)
        XCTAssertTrue(before.isEmpty, "пока встреча жива, запись к ней привязана и ad-hoc не является")

        try await repositories.meetings.delete(meetingIds: [event.id])
        let after = try await facade.adHocRecordings(from: from, to: to)

        XCTAssertEqual(ids(after), [orphaned.recordingId])
    }

    // MARK: - Инв. 33: окно

    /// Пересечение `[startedAt, endedAt)` с `[from, to)`: `startedAt < to` и (`endedAt == nil` либо
    /// `endedAt > from`). Границы полуоткрытые; незавершённая запись попадает.
    func test_inv33_windowIsHalfOpenIntersectionAndOpenRecordingIsIncluded() async throws {
        let repositories = InMemoryRepositories()
        let inside = try manifest(start: 120, end: 180)
        let straddlesFrom = try manifest(start: 50, end: 150)
        let straddlesTo = try manifest(start: 250, end: 400)
        let openBeforeWindow = try manifest(start: 10, end: nil)
        let endsAtFrom = try manifest(start: 0, end: 100)
        let startsAtTo = try manifest(start: 300, end: 350)
        let after = try manifest(start: 500, end: 600)
        let before = try manifest(start: 0, end: 50)
        let openAfterWindow = try manifest(start: 700, end: nil)
        for recorded in [inside, straddlesFrom, straddlesTo, openBeforeWindow, endsAtFrom, startsAtTo, after, before,
                         openAfterWindow] {
            repositories.recordings.seed([RecordingRecord(manifest: recorded, status: .finalized)])
        }

        let summaries = try await makeFacade(repositories).adHocRecordings(
            from: epoch.addingTimeInterval(100), to: epoch.addingTimeInterval(300)
        )

        XCTAssertEqual(
            Set(ids(summaries)),
            Set([inside, straddlesFrom, straddlesTo, openBeforeWindow].map(\.recordingId)),
            "endedAt == from и startedAt == to — вне окна; незавершённая запись, начатая до `to`, — внутри"
        )
    }

    // MARK: - Инв. 33: порядок

    func test_inv33_orderIsStartedAtThenUuidString() async throws {
        let repositories = InMemoryRepositories()
        let low = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
        let high = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-00000000000B"))
        let early = try manifest(id: UUID(), start: 10, end: 20)
        let tieHigh = try manifest(id: high, start: 30, end: 40)
        let tieLow = try manifest(id: low, start: 30, end: 40)
        let late = try manifest(id: UUID(), start: 50, end: 60)
        // Засев в порядке, отличном от ожидаемого.
        for recorded in [late, tieHigh, early, tieLow] {
            repositories.recordings.seed([RecordingRecord(manifest: recorded, status: .finalized)])
        }

        let (from, to) = wideWindow
        let summaries = try await makeFacade(repositories).adHocRecordings(from: from, to: to)

        XCTAssertEqual(ids(summaries), [early.recordingId, low, high, late.recordingId])
    }

    // MARK: - Инв. 33: разделение со списком встреч

    func test_inv33_meetingsDoesNotContainAdHocRecordings() async throws {
        let repositories = InMemoryRepositories()
        let facade = makeFacade(repositories)
        let event = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: []))
        let adHoc = try manifest(start: 0, end: 60)
        repositories.recordings.seed([RecordingRecord(manifest: adHoc, status: .finalized)])
        repositories.log.clear()

        let listed = try await facade.meetings(
            from: event.start.addingTimeInterval(-100_000_000), to: event.end.addingTimeInterval(100_000_000)
        )
        let listCalls = repositories.log.signatures
        let (from, to) = wideWindow
        let adHocSummaries = try await facade.adHocRecordings(from: from, to: to)

        XCTAssertEqual(listed.map(\.meetingId), [event.id], "вектор непустоты: встреча в списке есть")
        XCTAssertEqual(listed.first?.hasRecording, false, "ad-hoc запись встрече не приписана")
        XCTAssertFalse(listCalls.isEmpty, "журнал пишет чтение списка — иначе проверка ниже вакуумна")
        XCTAssertFalse(listCalls.contains("RecordingRepository.adHoc()"), "список ad-hoc не читает: \(listCalls)")
        XCTAssertEqual(ids(adHocSummaries), [adHoc.recordingId])
    }

    // MARK: - Инв. 33: модель — тот же код, что `MeetingDetail.recordings`

    func test_inv33_summaryIsBuiltByTheSameCodeAsMeetingDetail() async throws {
        let repositories = InMemoryRepositories()
        let facade = makeFacade(repositories)
        let event = MeetingEventFixtures.oneOnOneZoom
        try await repositories.meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: []))
        let recorded = try manifest(meetingId: event.id, start: 0, end: 60)
        repositories.recordings.seed([RecordingRecord(manifest: recorded, status: .finalized)])
        let base = TranscriptFixtures.oneOnOne
        _ = try await repositories.transcripts.save(try Transcript(
            recordingId: recorded.recordingId, language: base.language, engine: base.engine,
            modelVersion: base.modelVersion, createdAt: base.createdAt, segments: base.segments, speakers: base.speakers
        ))
        let detail = try await facade.meeting(id: event.id)
        let viaMeeting = try XCTUnwrap(detail?.recordings.first)

        try await repositories.meetings.delete(meetingIds: [event.id])
        let (from, to) = wideWindow
        let viaAdHoc = try await facade.adHocRecordings(from: from, to: to)

        XCTAssertFalse(viaMeeting.transcripts.isEmpty, "иначе равенство вакуумно")
        XCTAssertEqual(viaAdHoc, [viaMeeting])
    }

    // MARK: - Инв. 33: чтение без побочных эффектов

    func test_inv33_readHasNoSideEffects() async throws {
        let repositories = InMemoryRepositories()
        let facade = makeFacade(repositories)
        repositories.recordings.seed([RecordingRecord(manifest: try manifest(start: 0, end: 60), status: .finalized)])
        let storedBefore = repositories.recordings.storedRecords
        let events = facade.events()
        let (from, to) = wideWindow
        repositories.log.clear()

        let first = try await facade.adHocRecordings(from: from, to: to)
        let second = try await facade.adHocRecordings(from: from, to: to)

        XCTAssertEqual(first.count, 1, "вектор непустоты")
        XCTAssertEqual(first, second)
        let published = await collectEvents(events, count: 1, timeoutSeconds: 1)
        XCTAssertTrue(published.isEmpty, "чтение не публикует событий, пришло \(published)")
        // Журнал репозиториев (MEE-492): оба чтения дошли до `adHoc()`, и ни одного пишущего вызова.
        let calls = repositories.log.calls
        XCTAssertEqual(repositories.log.count(port: InMemoryRecordingRepository.portName, method: "adHoc()"), 2)
        let writes = calls.filter { call in Self.writingMethodPrefixes.contains { call.method.hasPrefix($0) } }
        XCTAssertEqual(writes, [], "чтение ничего не пишет: \(calls.map(\.signature))")
        XCTAssertEqual(repositories.recordings.storedRecords, storedBefore)
        XCTAssertTrue(repositories.recordings.directoriesCreated.isEmpty)
        XCTAssertTrue(repositories.recordings.directoriesAskedToDelete.isEmpty)
    }

    /// Пишущие методы портов хранилища (C-010) — по началу имени.
    private static let writingMethodPrefixes = [
        "save", "delete", "createDirectory", "setStatus", "upsert", "update", "assign", "clear", "rename",
        "forget", "merge", "replace", "insert", "remove", "set", "detach", "attach", "mark"
    ]

    /// Отказ хранилища сводится по §3.1, как у остальных чтений.
    func test_inv33_storageFailureIsWrappedLikeOtherReads() async throws {
        let repositories = InMemoryRepositories()
        repositories.recordings.fail(with: .io(message: "диск"), on: .adHoc)
        let (from, to) = wideWindow

        do {
            _ = try await makeFacade(repositories).adHocRecordings(from: from, to: to)
            XCTFail("отказ хранилища обязан дойти до вызывающей стороны")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertTrue(view.code.hasPrefix("storage."), "код \(view.code)")
        }
    }
}
