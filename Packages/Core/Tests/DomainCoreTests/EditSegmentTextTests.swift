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
}
