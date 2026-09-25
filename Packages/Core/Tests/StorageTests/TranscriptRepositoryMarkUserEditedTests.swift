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
