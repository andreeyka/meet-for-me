//  AppFacadeImplReadModelsTests — MEE-420 часть 2, план MEE-410, группы А (К4) и Б
//  (К5–К9), плюс К48(б) группы Х (реализована попутно — `openPermissionSettings` не
//  зависит ни от чего, что группы В–Ц ещё не дали). Предмет теста — реализация
//  `AppFacadeImpl` на прямых фейках портов/репозиториев, не `FakeAppFacade` (план
//  MEE-410, §0, правка РП п.1).

import XCTest
import DomainCore
import DomainTestKit

final class AppFacadeImplReadModelsTests: XCTestCase {

    /// Не `private` — используется и из `AppFacadeImplReadModelsTests+Return.swift`.
    let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    /// Тип, а не трёхчленный кортеж: `large_tuple` разрешает два члена. Не `private` — нужен
    /// файлу `AppFacadeImplReadModelsTests+Return.swift` (тот же класс, другой файл).
    struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let permissions: FakePermissionsPort
        let sessionCoordinator: FakeSessionCoordinator
    }

    func makeFacade(
        clock: @escaping @Sendable () -> Date = { Date() },
        permissions permissionsOverride: FakePermissionsPort? = nil,
        meetings meetingsOverride: ((InMemoryMeetingRepository) -> MeetingRepository)? = nil,
        transcripts transcriptsOverride: ((InMemoryTranscriptRepository) -> TranscriptRepository)? = nil
    ) -> Fixture {
        let repositories = InMemoryRepositories()
        let permissions = permissionsOverride
            ?? FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: epoch)
        let meetings = meetingsOverride?(repositories.meetings) ?? repositories.meetings
        let transcripts = transcriptsOverride?(repositories.transcripts) ?? repositories.transcripts
        let sessionCoordinator = FakeSessionCoordinator()
        let facade = AppFacadeImpl(
            meetings: meetings,
            recordings: repositories.recordings,
            transcripts: transcripts,
            persons: repositories.persons,
            permissions: permissions,
            modelCatalog: FakeModelCatalogPort(),
            calendar: FakeCalendarPort(),
            sessionCoordinator: sessionCoordinator,
            clock: clock
        )
        return Fixture(
            facade: facade, repositories: repositories, permissions: permissions, sessionCoordinator: sessionCoordinator
        )
    }

    // MARK: - К4 (инв. 3, 20): идемпотентность чтения

    func test_k04_meetingsIsIdempotentAcrossTwoCallsWithoutCommandsBetween() async throws {
        let fixture = makeFacade()
        let facade = fixture.facade
        let repositories = fixture.repositories
        let event = try event(id: UUID(), start: epoch, title: "Созвон")
        repositories.meetings.seed([MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: [])])

        let first = try await facade.meetings(
            from: epoch.addingTimeInterval(-3_600), to: epoch.addingTimeInterval(3_600)
        )
        let second = try await facade.meetings(
            from: epoch.addingTimeInterval(-3_600), to: epoch.addingTimeInterval(3_600)
        )

        XCTAssertEqual(first, second, "повторное чтение без команд между вызовами равно")
    }

    // MARK: - К5 (инв. 4): по возрастанию start, при равенстве — по meetingId

    func test_k05_meetingsSortedByStartThenMeetingId() async throws {
        let clock = ManualClock(now: epoch)
        let fixture = makeFacade(clock: { clock.now() })
        let facade = fixture.facade
        let repositories = fixture.repositories
        let earlierId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let laterId = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let sameStart = epoch.addingTimeInterval(600)
        let firstId = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let events = try [
            event(id: firstId, start: epoch, title: "Первая по времени"),
            event(id: laterId, start: sameStart, title: "Позже по id при равном start"),
            event(id: earlierId, start: sameStart, title: "Раньше по id при равном start")
        ]
        repositories.meetings.seed(
            events.map { MeetingRecord(event: $0, dedupKey: nil, status: .scheduled, sources: []) }
        )
        let expectedOrder = ["Первая по времени", "Раньше по id при равном start", "Позже по id при равном start"]

        let items = try await facade.meetings(from: epoch.addingTimeInterval(-1), to: epoch.addingTimeInterval(3_600))

        XCTAssertEqual(items.map(\.title), expectedOrder)

        // Инв. 4: «AppStatus.upcoming отсортирован так же» — тот же порядок с той же точки
        // отсчёта (clock() зафиксирован на epoch), без верхней границы.
        let status = await facade.status()
        XCTAssertEqual(
            status.upcoming.map(\.title), expectedOrder, "status().upcoming — та же сортировка, что meetings"
        )
    }

    /// К5, продолжение: `hasRecording`/`hasTranscript` — по фактическому наличию записи/
    /// транскрипта этой встречи, а не по умолчанию.
    func test_k05_meetingListItemFlagsRecordingAndTranscriptPresence() async throws {
        let fixture = makeFacade()
        let facade = fixture.facade
        let repositories = fixture.repositories
        let withBoth = try event(id: UUID(), start: epoch, title: "И запись, и транскрипт")
        let withNeither = try event(id: UUID(), start: epoch.addingTimeInterval(60), title: "Ни того, ни другого")
        repositories.meetings.seed([
            MeetingRecord(event: withBoth, dedupKey: nil, status: .ready, sources: []),
            MeetingRecord(event: withNeither, dedupKey: nil, status: .scheduled, sources: [])
        ])
        let recordingId = UUID()
        repositories.recordings.seed([RecordingRecord(
            manifest: try manifest(recordingId: recordingId, meetingId: withBoth.id), status: .finalized
        )])
        _ = try await repositories.transcripts.save(
            try Transcript(
                recordingId: recordingId, language: "ru", engine: "e", modelVersion: "1",
                createdAt: epoch, segments: [], speakers: []
            )
        )

        let items = try await facade.meetings(from: epoch.addingTimeInterval(-1), to: epoch.addingTimeInterval(3_600))

        let both = try XCTUnwrap(items.first { $0.meetingId == withBoth.id })
        XCTAssertTrue(both.hasRecording)
        XCTAssertTrue(both.hasTranscript)
        let neither = try XCTUnwrap(items.first { $0.meetingId == withNeither.id })
        XCTAssertFalse(neither.hasRecording)
        XCTAssertFalse(neither.hasTranscript)
    }

    // MARK: - К6 (инв. 5): segments по startMs, speakers по убыванию totalMs — см. файл +Return

    // MARK: - К7 (инв. 6): displayName синтезируется «Спикер N» при personId == nil

    func test_k07_speakerDisplayNameSynthesizedForUnknownClusterOtherwiseFromPerson() async throws {
        let fixture = makeFacade()
        let facade = fixture.facade
        let repositories = fixture.repositories
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let personId = try await repositories.persons.upsert(displayName: "Иван Петров", emails: ["ivan@example.com"])
        let speakers = try [
            Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 1_000),
            Transcript.Speaker(cluster: 1, embedding: nil, embeddingModelVersion: nil, totalMs: 1_000)
        ]
        let segments = try [
            segment(startMs: 0, endMs: 1_000, cluster: 0, text: "известный"),
            segment(startMs: 1_000, endMs: 2_000, cluster: 1, text: "неизвестный")
        ]
        let header = try await repositories.transcripts.save(
            try Transcript(
                recordingId: recordingId, language: "ru", engine: "e", modelVersion: "1",
                createdAt: epoch, segments: segments, speakers: speakers
            )
        )
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        let clusterZeroRow = try XCTUnwrap(rows.first { $0.segment.speakerCluster == 0 })
        try await repositories.transcripts.updateAttribution([
            SegmentAttributionUpdate(
                segmentId: clusterZeroRow.id, personId: personId,
                speakerConfidence: 0.9, attributionSource: .voiceProfile
            )
        ])
        // Кластер 1 никогда не проходил через updateAttribution — personId/attributionSource
        // остаются nil на своей строке с момента save(), тем же приёмом, что и любая другая
        // ещё не атрибутированная запись.

        let maybeView = try await facade.transcript(id: header.id)
        let view = try XCTUnwrap(maybeView)

        let known = try XCTUnwrap(view.speakers.first { $0.cluster == 0 })
        XCTAssertEqual(known.displayName, "Иван Петров")
        let unknown = try XCTUnwrap(view.speakers.first { $0.cluster == 1 })
        XCTAssertEqual(unknown.displayName, "Спикер 2", "cluster 1 -> N = 2, никогда не атрибутирован")
    }

    // MARK: - К8 (инв. 7, 8): isUncertain и lowConfidenceWordIndexes по порогам

    func test_k08_isUncertainAndLowConfidenceWordIndexesFollowThresholds() async throws {
        let fixture = makeFacade()
        let facade = fixture.facade
        let repositories = fixture.repositories
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let thresholds = AttributionThresholds.slice1Defaults
        let lowWord = try Transcript.Word(
            startMs: 0, endMs: 100, text: "тихо", confidence: thresholds.textConfidenceMax - 0.01, original: nil
        )
        let highWord = try Transcript.Word(
            startMs: 100, endMs: 200, text: "громко", confidence: thresholds.textConfidenceMax + 0.01, original: nil
        )
        let speakers = try [Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 1_000)]
        let segments = try [
            Transcript.Segment(
                startMs: 0, endMs: 200, channel: .system, speakerCluster: 0,
                text: "тихо громко", textOriginal: nil,
                textConfidence: thresholds.textConfidenceMax - 0.01, words: [lowWord, highWord]
            )
        ]
        let header = try await repositories.transcripts.save(
            try Transcript(
                recordingId: recordingId, language: "ru", engine: "e", modelVersion: "1",
                createdAt: epoch, segments: segments, speakers: speakers
            )
        )
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        let personId = try await repositories.persons.upsert(displayName: "Иван", emails: ["ivan@example.com"])
        try await repositories.transcripts.updateAttribution([
            SegmentAttributionUpdate(
                segmentId: rows[0].id, personId: personId,
                speakerConfidence: thresholds.confirmedConfidenceMin - 0.01, attributionSource: .voiceProfile
            )
        ])

        let maybeView = try await facade.transcript(id: header.id)
        let view = try XCTUnwrap(maybeView)

        let speaker = try XCTUnwrap(view.speakers.first)
        XCTAssertTrue(speaker.isUncertain, "confidence ниже confirmedConfidenceMin")
        let segmentView = try XCTUnwrap(view.segments.first)
        XCTAssertEqual(segmentView.lowConfidenceWordIndexes, [0], "только слово 0 ниже textConfidenceMax")
    }

    // К8, продолжение (случай isUncertain == false, confidence nil/на пороге) — см. файл +Return

    // MARK: - К9 (мех.): ни одного поля цвета/презентации в SpeakerView/SegmentView

    func test_k09_presentationModelsCarryNoColorFields() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/DomainCore/AppFacadeReadModels.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for needle in ["color", "Color", "colour", "hex", "rgba", "UIColor", "NSColor"] {
            XCTAssertFalse(source.contains(needle), "поле/тип \(needle) не место в моделях чтения")
        }
    }

    // Возврат приёмки bf060b8 п.1 (transcript(id:)) и п.2 (инв. 19 catch-all) — см. файл +Return

    // MARK: - К48(б), группа Х: code == "permissions.settingsPaneUnavailable", permissionKind == nil

    func test_k48b_openPermissionSettingsUnavailableGivesNilPermissionKind() async throws {
        let fixture = makeFacade()
        let facade = fixture.facade
        let permissions = fixture.permissions
        permissions.failOpenSettings(with: .settingsPaneUnavailable(kind: .microphone), for: .microphone)

        do {
            try await facade.openPermissionSettings(.microphone)
            XCTFail("ожидался settingsPaneUnavailable")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "permissions.settingsPaneUnavailable")
            XCTAssertNil(view.permissionKind, "дословно по критерию — не по значению case")
        }
    }

    // MARK: - Оснастка

    /// Не `private` — используется и из `AppFacadeImplReadModelsTests+Return.swift`.
    func event(id: UUID, start: Date, title: String) throws -> MeetingEvent {
        try MeetingEvent(
            id: id, sourceConnectorId: "eventkit", externalId: "evt-\(id.uuidString.prefix(8))", icalUid: nil,
            title: title, start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC",
            isAllDay: false, isCancelled: false, organizer: nil, attendees: [], location: nil,
            bodyText: nil, conference: nil, lastModified: start
        )
    }

    func segment(startMs: Int, endMs: Int, cluster: Int, text: String) throws -> Transcript.Segment {
        try Transcript.Segment(
            startMs: startMs, endMs: endMs, channel: .system, speakerCluster: cluster,
            text: text, textOriginal: nil, textConfidence: 0.9, words: []
        )
    }

    func manifest(recordingId: UUID, meetingId: UUID?) throws -> RecordingManifest {
        try RecordingManifest(
            recordingId: recordingId, meetingId: meetingId, directoryName: recordingId.uuidString,
            startedAt: epoch, endedAt: epoch.addingTimeInterval(600),
            tracks: [
                try RecordingManifest.Track(
                    channel: .mic, fileName: "audio-mic.m4a", sampleRate: 16_000, channelCount: 1, format: "aac-m4a"
                )
            ],
            markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [], discontinuities: [], isFinalized: true
        )
    }
}
