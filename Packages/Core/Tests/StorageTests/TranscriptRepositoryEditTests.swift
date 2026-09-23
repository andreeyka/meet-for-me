//  TranscriptRepositoryEditTests — К14, К16, К20, К22 перечня MEE-189
//  (группы B и D), владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class TranscriptRepositoryEditTests: StorageAsyncTestCase {

    // MARK: - К14

    /// (i) На пути записи домен отказывает ДО того, как строка дошла бы до базы:
    /// `Transcript.Segment` с `end_ms <= start_ms` не конструируется вовсе.
    func testK14i_invalidSegmentRejectedAtDomainConstruction() {
        XCTAssertThrowsError(try TestFixtures.segment(startMs: 100, endMs: 100, text: "bad"))
        XCTAssertThrowsError(try TestFixtures.segment(startMs: 100, endMs: 50, text: "bad"))
    }

    /// (ii) Те же значения, вставленные строкой мимо репозитория (в обход `CHECK`
    /// схемы — `PRAGMA ignore_check_constraints`, недостижимо обычным `INSERT`,
    /// раз DDL v7 сам запрещает `end_ms <= start_ms`), — чтение даёт `dataCorrupted`,
    /// а не `nil` и не выдачу без строки.
    func testK14ii_readingBrokenRowGivesDataCorrupted() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let header = try await transcripts.save(
            try TestFixtures.transcript(
                recordingId: recordingId, segments: [try TestFixtures.segment(startMs: 0, endMs: 10, text: "x")]
            )
        )

        try temp.database.rawWrite { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(
                sql: """
                INSERT INTO segments (transcript_id, start_ms, end_ms, channel, text, words_json, is_user_edited)
                VALUES (?, 100, 50, 'mic', 'broken', '[]', 0)
                """,
                arguments: [header.id.uuidString]
            )
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }

        do {
            _ = try await transcripts.transcript(id: header.id)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(let entity, _, _) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)"); return
            }
            XCTAssertEqual(entity, "Transcript", "entity — запрошенная сущность, а не таблица-источник")
        }
    }

    /// `speaker_confidence` вне `0...1` — не часть домена `Transcript.Segment` (поле
    /// атрибуции), поэтому проверяется отдельно в `segments(transcriptId:)`, а не
    /// через `transcript(id:)`.
    func testK14_speakerConfidenceOutOfRangeGivesDataCorruptedOnSegments() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingId = UUID()
        try await recordingRepository.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let header = try await transcripts.save(
            try TestFixtures.transcript(
                recordingId: recordingId, segments: [try TestFixtures.segment(startMs: 0, endMs: 10, text: "x")]
            )
        )
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE segments SET speaker_confidence = 5.0 WHERE transcript_id = ?",
                arguments: [header.id.uuidString]
            )
        }

        do {
            _ = try await transcripts.segments(transcriptId: header.id)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(let entity, _, _) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)"); return
            }
            XCTAssertEqual(entity, "Segment")
        }
    }
}
