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

    /// К109 (MEE-422, C-010 v25 инв. 34): два id разом; `text`/`textOriginal`/`words`
    /// каждой строки — непустые, различные, хотя бы одно слово несёт `original` ≠ `text` —
    /// метод оставляет все три колонки побайтово нетронутыми, меняет только флаг.
    func test_k109_marksTwoRowsAndLeavesTextTextOriginalWordsByteIdentical() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let segments = try [
            Self.segmentWithEditHistory(startMs: 0, endMs: 1_000, text: "Иван", original: "Ивам"),
            Self.segmentWithEditHistory(startMs: 1_000, endMs: 2_000, text: "Пётр", original: "Петр")
        ]
        let header = try await repositories.transcripts.save(try Self.transcript(
            for: recordingId, segments: segments
        ))
        let before = try await repositories.transcripts.segments(transcriptId: header.id)
        XCTAssertEqual(before.count, 2)

        try await repositories.transcripts.markSegmentsUserEdited(segmentIds: before.map(\.id))

        let after = try await repositories.transcripts.segments(transcriptId: header.id)
        for beforeRow in before {
            let afterRow = try XCTUnwrap(after.first { $0.id == beforeRow.id })
            XCTAssertTrue(afterRow.isUserEdited)
            XCTAssertEqual(afterRow.segment.text, beforeRow.segment.text, "text не тронут")
            XCTAssertEqual(afterRow.segment.textOriginal, beforeRow.segment.textOriginal, "textOriginal не тронут")
            XCTAssertEqual(afterRow.segment.words, beforeRow.segment.words, "words не тронуты")
        }
    }

    /// К111 (MEE-422, C-010 v25 инв. 34): откат не зависит от порядка обхода `Set` —
    /// три валидных id рядом с чужим, ни один валидный не помечается.
    func test_k111_atomicRollbackWithMultipleValidIdsDoesNotDependOnSetOrder() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let header = try await repositories.transcripts.save(try Self.transcript(for: recordingId))
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        XCTAssertEqual(rows.count, 3)

        do {
            try await repositories.transcripts.markSegmentsUserEdited(segmentIds: rows.map(\.id) + [999_999])
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let after = try await repositories.transcripts.segments(transcriptId: header.id)
        for row in rows {
            XCTAssertFalse(
                after.first { $0.id == row.id }?.isUserEdited ?? true, "id \(row.id) — откат целиком, не помечен"
            )
        }
    }

    /// К114 (MEE-422), случай (i): `is_user_edited` выставлен через `markSegmentsUserEdited`,
    /// не через `updateSegmentText` (случай (ii), уже покрыт `test_mee290_…` в
    /// `InMemoryTranscriptRepositoryTests.swift`) — `.user`-присвоение всё равно проходит.
    func test_k114_caseIFlagFromMarkSegmentsUserEditedStillAllowsUserSourceWrite() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let header = try await repositories.transcripts.save(try Self.transcript(for: recordingId))
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        let userPersonId = UUID()

        try await repositories.transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id])
        try await repositories.transcripts.updateAttribution([
            SegmentAttributionUpdate(
                segmentId: rows[0].id, personId: userPersonId, speakerConfidence: 1.0, attributionSource: .user
            )
        ])

        let after = try await repositories.transcripts.segments(transcriptId: header.id)
        let updated = try XCTUnwrap(after.first { $0.id == rows[0].id })
        XCTAssertEqual(updated.personId, userPersonId, "запись прошла, несмотря на isUserEdited")
        XCTAssertEqual(updated.attributionSource, .user)
        XCTAssertTrue(updated.isUserEdited)
    }

    /// К115 (MEE-422, C-010 v25 инв. 17, базовое правило): строка, помеченная случаем (i)
    /// К114 и уже несущая `.user`-присвоение, — следующий автоматический вызов её пропускает
    /// молча, присвоение `.user` и флаг не меняются.
    func test_k115_automaticUpdateAfterUserWriteIsSkippedSilently() async throws {
        let repositories = InMemoryRepositories()
        let recordingId = RecordingManifestFixtures.hourlyTwoChannels.recordingId
        let header = try await repositories.transcripts.save(try Self.transcript(for: recordingId))
        let rows = try await repositories.transcripts.segments(transcriptId: header.id)
        let userPersonId = UUID()
        let automaticPersonId = UUID()

        try await repositories.transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id])
        try await repositories.transcripts.updateAttribution([
            SegmentAttributionUpdate(
                segmentId: rows[0].id, personId: userPersonId, speakerConfidence: 1.0, attributionSource: .user
            )
        ])

        try await repositories.transcripts.updateAttribution([
            SegmentAttributionUpdate(
                segmentId: rows[0].id, personId: automaticPersonId, speakerConfidence: 0.2,
                attributionSource: .oneOnOne
            )
        ])

        let after = try await repositories.transcripts.segments(transcriptId: header.id)
        let stillProtected = try XCTUnwrap(after.first { $0.id == rows[0].id })
        XCTAssertEqual(stillProtected.personId, userPersonId, "автоматика не перезаписала .user-присвоение")
        XCTAssertEqual(stillProtected.attributionSource, .user)
        XCTAssertTrue(stillProtected.isUserEdited)
    }

    // MARK: - Оснастка

    private static func segmentWithEditHistory(
        startMs: Int, endMs: Int, text: String, original: String
    ) throws -> Transcript.Segment {
        let word = try Transcript.Word(
            startMs: startMs, endMs: startMs + 100, text: text, confidence: 0.9, original: original
        )
        return try Transcript.Segment(
            startMs: startMs, endMs: endMs, channel: .mic, speakerCluster: nil,
            text: text, textOriginal: original, textConfidence: 0.9, words: [word]
        )
    }

    private static func transcript(for recordingId: UUID) throws -> Transcript {
        try transcript(for: recordingId, segments: [
            try segment(startMs: 0, endMs: 1_000, text: "alpha"),
            try segment(startMs: 1_000, endMs: 2_000, text: "bravo"),
            try segment(startMs: 2_000, endMs: 3_000, text: "charlie")
        ])
    }

    private static func transcript(for recordingId: UUID, segments: [Transcript.Segment]) throws -> Transcript {
        try Transcript(
            recordingId: recordingId, language: "ru", engine: "gigaam", modelVersion: "v2",
            createdAt: Date(timeIntervalSince1970: 1_789_120_800),
            segments: segments,
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
