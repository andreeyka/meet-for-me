//  TranscriptRepositoryTests — К12—К14, К16, К20, К22, К23 перечня MEE-189
//  (группы B и D), владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class TranscriptRepositoryTests: StorageAsyncTestCase {

    // MARK: - К12

    func testK12_deleteRecordingCascadesTranscriptsSegmentsAndFTS() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcriptRepository = temp.database.transcriptRepository()

        let recordingId = try await Self.makeRecording(repository: recordingRepository, layout: layout)
        let first = try await Self.saveThreeSegments(recordingId, "one", transcriptRepository)
        let second = try await Self.saveThreeSegments(recordingId, "two", transcriptRepository)

        try await recordingRepository.delete(recordingId: recordingId, deleteFiles: false)

        let ids = StatementArguments([first.id.uuidString, second.id.uuidString])
        let segmentsCount = try temp.database.rawRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments WHERE transcript_id IN (?, ?)", arguments: ids)
        }
        XCTAssertEqual(segmentsCount, 0, "segments каскадом удалены вместе с transcripts")
        try await Self.assertFTSMatchesSegments(temp.database)
        let ftsCount = try Self.ftsCount(temp.database)
        XCTAssertEqual(ftsCount, 0, "в segments_fts не осталось строк удалённых сегментов")

        let hits = try await transcriptRepository.search(query: "alpha", limit: 10, offset: 0)
        XCTAssertTrue(hits.isEmpty, "поиск по тексту удалённого сегмента не находит ничего")
    }

    // MARK: - К13

    func testK13_ftsStaysInSyncAfterEveryOperation() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordingRepository = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()

        let recordingA = try await Self.makeRecording(repository: recordingRepository, layout: layout)
        let recordingB = try await Self.makeRecording(repository: recordingRepository, layout: layout)

        func update(_ segmentId: Int64, _ text: String) async throws {
            try await transcripts.updateSegmentText(segmentId: segmentId, text: text, isUserEdited: true)
        }
        func check() async throws { try await Self.assertFTSMatchesSegments(temp.database) }

        // 1—2: save на обеих записях.
        let a1 = try await Self.saveThreeSegments(recordingA, "a1", transcripts); try await check()
        let b1 = try await Self.saveThreeSegments(recordingB, "b1", transcripts); try await check()

        // 3—4: updateSegmentText на первом сегменте каждого транскрипта.
        let a1Rows = try await transcripts.segments(transcriptId: a1.id)
        try await update(a1Rows[0].id, "a1 renamed"); try await check()
        let oldHits = try await transcripts.search(query: "alpha", limit: 20, offset: 0)
        XCTAssertFalse(oldHits.contains { $0.segmentId == a1Rows[0].id }, "прежний текст не находится")
        let newHits = try await transcripts.search(query: "renamed", limit: 20, offset: 0)
        XCTAssertTrue(newHits.contains { $0.segmentId == a1Rows[0].id }, "новый текст находится")

        let b1Rows = try await transcripts.segments(transcriptId: b1.id)
        try await update(b1Rows[0].id, "b1 renamed"); try await check()

        // 5—6: второй транскрипт на A, обновление в нём.
        let a2 = try await Self.saveThreeSegments(recordingA, "a2", transcripts); try await check()
        let a2Rows = try await transcripts.segments(transcriptId: a2.id)
        try await update(a2Rows[1].id, "a2 bravo updated"); try await check()

        // 7—8: второй транскрипт на B, обновление в нём.
        let b2 = try await Self.saveThreeSegments(recordingB, "b2", transcripts); try await check()
        let b2Rows = try await transcripts.segments(transcriptId: b2.id)
        try await update(b2Rows[2].id, "b2 charlie updated"); try await check()

        // 9: удаление записи B — оба её транскрипта и шесть сегментов уходят разом.
        try await recordingRepository.delete(recordingId: recordingB, deleteFiles: false); try await check()

        // 10—11: ещё два обновления на A, включая сегмент второго транскрипта.
        try await update(a1Rows[1].id, "a1 bravo updated"); try await check()
        try await update(a2Rows[0].id, "a2 alpha updated"); try await check()

        // 12: обновление текста сегмента и следующее за ним удаление его транскрипта
        // (через удаление владеющей им записи — прямого delete у TranscriptRepository нет).
        try await update(a2Rows[2].id, "a2 charlie updated")
        try await recordingRepository.delete(recordingId: recordingA, deleteFiles: false)
        try await check()

        XCTAssertEqual(try Self.ftsCount(temp.database), 0)
    }

    // MARK: - Оснастка

    private static func makeRecording(repository: RecordingRepository, layout: FileLayout) async throws -> UUID {
        let id = UUID()
        let manifest = try TestFixtures.recordingManifest(recordingId: id)
        try await repository.save(RecordingRecord(manifest: manifest, status: .recording))
        return id
    }

    private static func saveThreeSegments(
        _ recordingId: UUID, _ prefix: String, _ repository: TranscriptRepository
    ) async throws -> TranscriptHeader {
        let segments = try TestFixtures.threeDistinctSegments(prefix: prefix)
        return try await repository.save(try TestFixtures.transcript(recordingId: recordingId, segments: segments))
    }

    private static func ftsCount(_ database: StorageDatabase) throws -> Int? {
        try database.rawRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments_fts") }
    }

    private static func assertFTSMatchesSegments(
        _ database: StorageDatabase, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let segmentsCount = try database.rawRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM segments") }
        let fts = try ftsCount(database)
        XCTAssertEqual(fts, segmentsCount, "segments_fts разошёлся с segments", file: file, line: line)
    }
}
