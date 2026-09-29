//  SpeakersMigrationV1Slice3Tests — миграция `v1-slice3` и неизменность
//  `speakers_json` под правками сегментов, C-010 v28 §3.2 и инвариант 38 (IR-153,
//  MEE-490), MEE-505 критерии 1, 5, 7. Владелец: DEV-2.
//
//  Критерий 5 строит базу на `v1-slice1` + `v1-slice2` напрямую (не через
//  `StorageDatabase`, чей инициализатор гоняет полный мигратор) — тот же приём, что
//  `MigrationV1Slice2Tests`; затем открывает файл штатным `StorageDatabase(path:)`,
//  и GRDB применяет только недостающую `v1-slice3`.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class SpeakersMigrationV1Slice3Tests: StorageAsyncTestCase {

    // MARK: - Критерий 1

    func testZ8_1_migrationsAndSpeakersJSONColumn() throws {
        XCTAssertEqual(StorageMigrations.migrator.migrations, ["v1-slice1", "v1-slice2", "v1-slice3"])
        XCTAssertFalse(StorageMigrations.schemaSQL.contains("speakers_json"), "блок v1-slice1 не тронут")

        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let column = try temp.database.rawRead { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(transcripts)").first { $0["name"] == "speakers_json" }
        }
        let info = try XCTUnwrap(column, "PRAGMA table_info(transcripts) не знает speakers_json")
        XCTAssertEqual(info["type"] as String, "TEXT")
        XCTAssertEqual(info["notnull"] as Int, 0, "колонка допускает NULL")
        XCTAssertNil(info["dflt_value"] as String?, "значения по умолчанию нет")
    }

    // MARK: - Критерий 5

    func testZ8_5_rowWrittenBeforeV1Slice3IsReadWithReconstructedSpeakers() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-v1slice3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("db.sqlite")

        let transcriptId = try Self.seedBeforeV1Slice3(at: databaseURL)
        let database = try StorageDatabase(path: databaseURL)

        let raw = try SpeakersFixtures.speakersJSON(database, transcriptId)
        XCTAssertNil(raw, "после миграции speakers_json IS NULL у строки до v1-slice3")
        let maybeRead = try await database.transcriptRepository().transcript(id: transcriptId)
        let read = try XCTUnwrap(maybeRead)
        XCTAssertEqual(read.speakers, [
            try Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 2_500),
            try Transcript.Speaker(cluster: 2, embedding: nil, embeddingModelVersion: nil, totalMs: 700)
        ], "по одному на кластер по возрастанию, embedding nil, totalMs — сумма")
    }

    /// База на `v1-slice1` + `v1-slice2`: запись, транскрипт и сегменты так, как их писал
    /// `save` до этого издания (без колонки `speakers_json`). Кластеры 2, 0, 0 и `mic`
    /// без кластера — порядок вставки не совпадает с порядком кластеров.
    private static func seedBeforeV1Slice3(at url: URL) throws -> UUID {
        let queue = try DatabaseQueue(path: url.path)
        var beforeSlice3 = DatabaseMigrator()
        beforeSlice3.registerMigration("v1-slice1") { db in try db.execute(sql: StorageMigrations.schemaSQL) }
        beforeSlice3.registerMigration("v1-slice2") { db in
            try db.execute(sql: "ALTER TABLE meeting_sources ADD COLUMN raw_payload_json TEXT")
        }
        try beforeSlice3.migrate(queue)

        let recordingId = UUID().uuidString
        let transcriptId = UUID()
        try queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO recordings
                    (id, directory_name, started_at, manifest_json, is_finalized, status, created_at, updated_at)
                VALUES (?, ?, 0, '{}', 0, 'recording', 0, 0)
                """,
                arguments: [recordingId, recordingId]
            )
            try db.execute(
                sql: """
                INSERT INTO transcripts (id, recording_id, file_index, engine, model_version, language, created_at)
                VALUES (?, ?, 1, 'engine', '1.0', 'ru', 0)
                """,
                arguments: [transcriptId.uuidString, recordingId]
            )
            for (start, end, channel, cluster) in [
                (0, 700, "system", 2 as Int?), (700, 2_000, "system", 0), (2_000, 2_500, "mic", nil),
                (3_000, 4_200, "system", 0)
            ] {
                try db.execute(
                    sql: """
                    INSERT INTO segments (transcript_id, start_ms, end_ms, channel, cluster, text, words_json)
                    VALUES (?, ?, ?, ?, ?, 'до миграции', '[]')
                    """,
                    arguments: [transcriptId.uuidString, start, end, channel, cluster]
                )
            }
        }
        return transcriptId
    }

    // MARK: - Критерий 7

    func testZ8_7_segmentUpdatesDoNotTouchSpeakersJSON() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let recordingId = try await SpeakersFixtures.makeRecording(temp.database)
        let original = try Self.transcriptWithWords(recordingId: recordingId)
        let repository = temp.database.transcriptRepository()
        let header = try await repository.save(original)
        let before = try XCTUnwrap(try SpeakersFixtures.speakersJSON(temp.database, header.id))
        let rows = try await repository.segments(transcriptId: header.id)

        try await repository.updateAttribution([
            SegmentAttributionUpdate(
                segmentId: rows[0].id, personId: nil, speakerConfidence: 0.5, attributionSource: .voiceProfile
            )
        ])
        XCTAssertEqual(try SpeakersFixtures.speakersJSON(temp.database, header.id), before, "updateAttribution")

        try await repository.applyTextCorrections(segmentId: rows[1].id, text: "Мария", corrections: [
            TextCorrection(
                segmentId: rows[1].id, wordIndex: 0, original: "мара", replacement: "Мария",
                personId: UUID(), similarity: 0.9
            )
        ])
        XCTAssertEqual(try SpeakersFixtures.speakersJSON(temp.database, header.id), before, "applyTextCorrections")

        try await repository.updateSegmentText(segmentId: rows[0].id, text: "правка", isUserEdited: true)
        XCTAssertEqual(try SpeakersFixtures.speakersJSON(temp.database, header.id), before, "updateSegmentText")

        try await repository.markSegmentsUserEdited(segmentIds: [rows[1].id])
        XCTAssertEqual(try SpeakersFixtures.speakersJSON(temp.database, header.id), before, "markSegmentsUserEdited")

        let maybeRead = try await repository.transcript(id: header.id)
        XCTAssertEqual(try XCTUnwrap(maybeRead).speakers, original.speakers)
    }

    /// Два сегмента `system` кластеров 3 и 0; у второго одно слово — цель постправки.
    private static func transcriptWithWords(recordingId: UUID) throws -> Transcript {
        let base = try SpeakersFixtures.twoSpeakersTranscript(recordingId: recordingId)
        let second = base.segments[1]
        let withWord = try Transcript.Segment(
            startMs: second.startMs, endMs: second.endMs, channel: second.channel,
            speakerCluster: second.speakerCluster, text: "мара", textOriginal: nil, textConfidence: nil,
            words: [Transcript.Word(startMs: second.startMs, endMs: second.endMs, text: "мара",
                                    confidence: nil, original: nil)]
        )
        return try TestFixtures.transcript(
            recordingId: recordingId, segments: [base.segments[0], withWord], speakers: base.speakers
        )
    }
}
