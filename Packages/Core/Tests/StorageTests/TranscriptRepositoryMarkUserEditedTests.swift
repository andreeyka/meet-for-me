//  TranscriptRepositoryMarkUserEditedTests — `markSegmentsUserEdited`, C-010 v25
//  инвариант 34 (IR-135, MEE-421), владелец: DEV-2.

import XCTest
import DomainCore
@testable import Storage

final class TranscriptRepositoryMarkUserEditedTests: StorageAsyncTestCase {

    func testMarkSegmentsUserEdited_setsOnlyIsUserEditedFlag() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let segments = try TestFixtures.threeDistinctSegments(prefix: "mark")
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: segments)
        )
        let rows = try await transcripts.segments(transcriptId: header.id)

        try await transcripts.markSegmentsUserEdited(segmentIds: [rows[1].id])

        let after = try await transcripts.segments(transcriptId: header.id)
        let marked = try XCTUnwrap(after.first { $0.id == rows[1].id })
        XCTAssertTrue(marked.isUserEdited)
        XCTAssertEqual(marked.segment.text, rows[1].segment.text, "text не тронут")
        XCTAssertEqual(marked.segment.textOriginal, rows[1].segment.textOriginal, "textOriginal не тронут")
        XCTAssertEqual(marked.segment.words, rows[1].segment.words, "words не тронуты")
        XCTAssertNil(marked.personId, "атрибуция не тронута")
        for row in after where row.id != rows[1].id {
            XCTAssertFalse(row.isUserEdited, "остальные сегменты не тронуты")
        }
    }

    func testMarkSegmentsUserEdited_alreadyMarkedRowIsNotAnError() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let segments = try TestFixtures.threeDistinctSegments(prefix: "twice")
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: segments)
        )
        let rows = try await transcripts.segments(transcriptId: header.id)

        try await transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id])
        try await transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id])

        let after = try await transcripts.segments(transcriptId: header.id)
        XCTAssertTrue(after.first { $0.id == rows[0].id }?.isUserEdited ?? false)
    }

    func testMarkSegmentsUserEdited_unknownIdThrowsConstraintViolation() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let transcripts = temp.database.transcriptRepository()

        do {
            try await transcripts.markSegmentsUserEdited(segmentIds: [999_999])
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }
    }

    func testMarkSegmentsUserEdited_emptyListIsNoOp() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let segments = try TestFixtures.threeDistinctSegments(prefix: "empty")
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: segments)
        )

        try await transcripts.markSegmentsUserEdited(segmentIds: [])

        let after = try await transcripts.segments(transcriptId: header.id)
        XCTAssertTrue(after.allSatisfy { !$0.isUserEdited }, "ничего не помечено")
    }

    func testMarkSegmentsUserEdited_duplicateIdInListMarksOnce() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let segments = try TestFixtures.threeDistinctSegments(prefix: "dup")
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: segments)
        )
        let rows = try await transcripts.segments(transcriptId: header.id)

        try await transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id, rows[0].id])

        let after = try await transcripts.segments(transcriptId: header.id)
        XCTAssertTrue(after.first { $0.id == rows[0].id }?.isUserEdited ?? false)
    }

    /// К109 (MEE-422, C-010 v25 инв. 34): два id разом; `text`/`textOriginal`/`words`
    /// каждой строки — непустые, различные, хотя бы одно слово несёт `original` ≠ `text` —
    /// метод оставляет все три колонки побайтово нетронутыми, меняет только флаг.
    func testK109_marksTwoRowsAndLeavesTextTextOriginalWordsByteIdentical() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let segments = try [
            TestFixtures.segmentWithEditHistory(
                startMs: 0, endMs: 1_000, text: "Иван", textOriginal: "Ивам", wordOriginal: "Ивам"
            ),
            TestFixtures.segmentWithEditHistory(
                startMs: 1_000, endMs: 2_000, text: "Пётр", textOriginal: "Петр", wordOriginal: "Петр"
            )
        ]
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: segments)
        )
        let before = try await transcripts.segments(transcriptId: header.id)
        XCTAssertEqual(before.count, 2)

        try await transcripts.markSegmentsUserEdited(segmentIds: before.map(\.id))

        let after = try await transcripts.segments(transcriptId: header.id)
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
    func testK111_atomicRollbackWithMultipleValidIdsDoesNotDependOnSetOrder() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let segments = try TestFixtures.threeDistinctSegments(prefix: "k111")
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: segments)
        )
        let rows = try await transcripts.segments(transcriptId: header.id)
        XCTAssertEqual(rows.count, 3)

        do {
            try await transcripts.markSegmentsUserEdited(segmentIds: rows.map(\.id) + [999_999])
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let after = try await transcripts.segments(transcriptId: header.id)
        for row in rows {
            XCTAssertFalse(
                after.first { $0.id == row.id }?.isUserEdited ?? true, "id \(row.id) — откат целиком, не помечен"
            )
        }
    }

    /// Атомарность: список несёт валидный id и чужой — валидный не помечается тоже.
    func testMarkSegmentsUserEdited_atomicRollbackOnUnknownIdMarksNothing() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let segments = try TestFixtures.threeDistinctSegments(prefix: "atomic")
        let header = try await transcripts.save(
            try TestFixtures.transcript(recordingId: recordingId, segments: segments)
        )
        let rows = try await transcripts.segments(transcriptId: header.id)

        do {
            try await transcripts.markSegmentsUserEdited(segmentIds: [rows[0].id, 999_999])
            XCTFail("ожидался constraintViolation")
        } catch StorageError.constraintViolation {
            // ожидаемо
        }

        let after = try await transcripts.segments(transcriptId: header.id)
        XCTAssertFalse(after.first { $0.id == rows[0].id }?.isUserEdited ?? true, "откат — валидный id тоже не помечен")
    }
}
