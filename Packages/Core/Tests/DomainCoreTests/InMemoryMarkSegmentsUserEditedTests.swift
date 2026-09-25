//  InMemoryMarkSegmentsUserEditedTests — `markSegmentsUserEdited` фейка,
//  C-010 v25 инвариант 34 (IR-135, MEE-421) — те же векторы, что
//  `TranscriptRepositoryMarkUserEditedTests.swift` (StorageTests, GRDB).

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryMarkSegmentsUserEditedTests: XCTestCase {

    func test_setsOnlyIsUserEditedFlag() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let header = try await repositories.transcripts.save(try Self.transcript(for: recordingId))
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)

        try await repositories.transcripts.markSegmentsUserEdited(segmentIds: [rows[1].id])

        let after = try await repositories.transcripts.segments(transcriptId: header.id)
        let marked = try XCTUnwrap(after.first { $0.id == rows[1].id })
        XCTAssertTrue(marked.isUserEdited)
        XCTAssertEqual(marked.segment.text, rows[1].segment.text, "text не тронут")
        XCTAssertNil(marked.personId, "атрибуция не тронута")
        for row in after where row.id != rows[1].id {
            XCTAssertFalse(row.isUserEdited, "остальные не тронуты")
        }
    }

    func test_alreadyMarkedRowIsNotAnError() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let header = try await repositories.transcripts.save(try Self.transcript(for: recordingId))
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)

        try await repositories.transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id])
        try await repositories.transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id])

        let after = try await repositories.transcripts.segments(transcriptId: header.id)
        XCTAssertTrue(after.first { $0.id == rows[0].id }?.isUserEdited ?? false)
    }

    func test_unknownIdThrowsConstraintViolation() async throws {
        let repositories = InMemoryRepositories()
        do {
            try await repositories.transcripts.markSegmentsUserEdited(segmentIds: [999_999])
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }
    }

    func test_emptyListIsNoOp() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let header = try await repositories.transcripts.save(try Self.transcript(for: recordingId))

        try await repositories.transcripts.markSegmentsUserEdited(segmentIds: [])

        let after = try await repositories.transcripts.segments(transcriptId: header.id)
        XCTAssertTrue(after.allSatisfy { !$0.isUserEdited }, "ничего не помечено")
    }

    func test_duplicateIdInListMarksOnce() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let header = try await repositories.transcripts.save(try Self.transcript(for: recordingId))
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)

        try await repositories.transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id, rows[0].id])

        let after = try await repositories.transcripts.segments(transcriptId: header.id)
        XCTAssertTrue(after.first { $0.id == rows[0].id }?.isUserEdited ?? false)
    }

    /// Атомарность: валидный id рядом с чужим — фейк проверяет существование ВСЕХ id
    /// до первой записи, поэтому валидный тоже остаётся непомеченным.
    func test_atomicRollbackOnUnknownIdMarksNothing() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let header = try await repositories.transcripts.save(try Self.transcript(for: recordingId))
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)

        do {
            try await repositories.transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id, 999_999])
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let after = try await repositories.transcripts.segments(transcriptId: header.id)
        XCTAssertFalse(after.first { $0.id == rows[0].id }?.isUserEdited ?? true, "валидный id тоже не помечен")
    }

    // MARK: - Оснастка

    private static func transcript(for recordingId: UUID) throws -> Transcript {
        try Transcript(
            recordingId: recordingId, language: "ru", engine: "gigaam", modelVersion: "v2",
            createdAt: Date(timeIntervalSince1970: 1_789_120_800),
            segments: [
                try segment(startMs: 0, endMs: 1_000, text: "alpha"),
                try segment(startMs: 1_000, endMs: 2_000, text: "bravo"),
                try segment(startMs: 2_000, endMs: 3_000, text: "charlie")
            ],
            speakers: []
        )
    }

    private static func segment(startMs: Int, endMs: Int, text: String) throws -> Transcript.Segment {
        try Transcript.Segment(
            startMs: startMs, endMs: endMs, channel: .mic, speakerCluster: nil,
            text: text, textOriginal: nil, textConfidence: nil, words: []
        )
    }
}
