//  EditSegmentTextTests — MEE-420 часть 4, план MEE-410, группа Г (К13-К14):
//  `AppFacadeImpl.editSegmentText(segmentId:text:)` на прямых фейках репозиториев, не
//  `FakeAppFacade` (план MEE-410, §0).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class EditSegmentTextTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let transcriptId: UUID
        let segmentId: Int64

        func segmentRow() async throws -> SegmentRow {
            let rows = try await repositories.transcripts.segments(transcriptId: transcriptId)
            return try XCTUnwrap(rows.first { $0.id == segmentId })
        }
    }

    private static let updateSegmentTextMethod = "updateSegmentText(segmentId:text:isUserEdited:)"
    private static let applyTextCorrectionsMethod = "applyTextCorrections(segmentId:text:corrections:)"

    private func makeFixture() async throws -> Fixture {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let segment = try Transcript.Segment(
            startMs: 0, endMs: 800, channel: .mic, speakerCluster: nil,
            text: "исходный текст", textOriginal: nil, textConfidence: nil, words: []
        )
        let transcript = try Transcript(
            recordingId: recordingId, language: "ru", engine: "engine", modelVersion: "1.0",
            createdAt: Date(timeIntervalSince1970: 0), segments: [segment], speakers: []
        )
        let header = try await repositories.transcripts.save(transcript)
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        let segmentId = try XCTUnwrap(rows.first).id
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
            jobQueue: FakeJobQueue(),
            fileLayout: FileLayout(root: FileManager.default.temporaryDirectory),
            clock: { Date() }
        )
        return Fixture(facade: facade, repositories: repositories, transcriptId: header.id, segmentId: segmentId)
    }

    // MARK: - К13 (инв. 13, ч.1): ровно один вызов updateSegmentText(isUserEdited: true), без applyTextCorrections

    func test_k13_editSegmentTextCallsUpdateSegmentTextOnce() async throws {
        let fixture = try await makeFixture()

        try await fixture.facade.editSegmentText(segmentId: fixture.segmentId, text: "новый текст")

        let updateCalls = fixture.repositories.log.calls(port: "TranscriptRepository")
            .filter { $0.method == Self.updateSegmentTextMethod }
        XCTAssertEqual(updateCalls.count, 1)
        XCTAssertEqual(
            fixture.repositories.log.count(port: "TranscriptRepository", method: Self.applyTextCorrectionsMethod), 0
        )
        XCTAssertEqual(updateCalls.first?.arguments.last, "true", "isUserEdited: true")

        let row = try await fixture.segmentRow()
        XCTAssertEqual(row.segment.text, "новый текст")
        XCTAssertTrue(row.isUserEdited)
    }

    // MARK: - К14: повторная правка того же сегмента — тот же путь, не applyTextCorrections

    func test_k14_secondEditReusesUpdateSegmentTextNotApplyTextCorrections() async throws {
        let fixture = try await makeFixture()

        try await fixture.facade.editSegmentText(segmentId: fixture.segmentId, text: "первая правка")
        try await fixture.facade.editSegmentText(segmentId: fixture.segmentId, text: "вторая правка")

        XCTAssertEqual(
            fixture.repositories.log.count(port: "TranscriptRepository", method: Self.updateSegmentTextMethod), 2
        )
        XCTAssertEqual(
            fixture.repositories.log.count(port: "TranscriptRepository", method: Self.applyTextCorrectionsMethod), 0
        )

        // MEE-448 (сверка покрытия `484179e8`): второй вызов идёт тем же `updateSegmentText`
        // с `isUserEdited: true` на уже помеченной строке, и текст второй правки применён —
        // не пропущен, как пропустил бы его `applyTextCorrections` (инв. 32 C-010).
        let updateCalls = fixture.repositories.log.calls(port: "TranscriptRepository")
            .filter { $0.method == Self.updateSegmentTextMethod }
        let second = try XCTUnwrap(updateCalls.last)
        XCTAssertEqual(second.arguments, [String(fixture.segmentId), "вторая правка", "true"])
        let row = try await fixture.segmentRow()
        XCTAssertEqual(row.segment.text, "вторая правка", "текст второй правки применён")
        XCTAssertTrue(row.isUserEdited)
    }

    // MARK: - Приёмка РП 10:35 UTC: неизвестный сегмент → storage.notFound

    func test_editSegmentTextOnUnknownSegmentThrowsStorageNotFound() async throws {
        let fixture = try await makeFixture()
        let unknownSegmentId: Int64 = fixture.segmentId + 1

        do {
            try await fixture.facade.editSegmentText(segmentId: unknownSegmentId, text: "неважно")
            XCTFail("ожидался AppFacadeError.underlying(storage.notFound)")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "storage.notFound")
        }
    }

    // MARK: - К33 (инв. 15 C-016; C-010 v26, инв. 35, MEE-445): публикация .transcriptChanged

    /// Ровно одно событие, и это `.transcriptChanged` с `transcriptId` того транскрипта,
    /// чей сегмент изменён. Подписка — до команды (broadcaster без буфера). Второе событие
    /// ждётся коротким окном: его отсутствие и есть «ровно одно».
    func test_mee445_editSegmentTextPublishesExactlyOneTranscriptChanged() async throws {
        let fixture = try await makeFixture()
        let stream = fixture.facade.events()

        try await fixture.facade.editSegmentText(segmentId: fixture.segmentId, text: "новый текст")

        let events = await collectEvents(stream, count: 2, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 1, "\(events)")
        guard case .transcriptChanged(let transcriptId) = events.first else {
            return XCTFail("ожидался .transcriptChanged, получено \(String(describing: events.first))")
        }
        XCTAssertEqual(transcriptId, fixture.transcriptId)
    }

    /// Отказ записи (неизвестный сегмент) не публикует ничего: событие — следствие
    /// изменения, а не попытки.
    func test_mee445_failedEditSegmentTextPublishesNothing() async throws {
        let fixture = try await makeFixture()
        let stream = fixture.facade.events()

        do {
            try await fixture.facade.editSegmentText(segmentId: fixture.segmentId + 1, text: "неважно")
            XCTFail("ожидался отказ")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "storage.notFound")
        }

        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)
        XCTAssertTrue(events.isEmpty, "\(events)")
    }
}
