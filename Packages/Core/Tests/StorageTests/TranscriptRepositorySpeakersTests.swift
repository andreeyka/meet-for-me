//  TranscriptRepositorySpeakersTests — круг «запись → чтение» `Transcript.speakers`
//  через `transcripts.speakers_json`, C-010 v28 инвариант 38 (IR-153, MEE-490),
//  MEE-505 критерии 2, 3, 4, 6, 8. Владелец: DEV-2.
//
//  Критерии 1, 5, 7 — в `SpeakersMigrationV1Slice3Tests.swift`.

import XCTest
import GRDB
import DomainCore
import DomainTestKit
@testable import Storage

final class TranscriptRepositorySpeakersTests: StorageAsyncTestCase {

    // MARK: - Критерий 2

    /// Порядок `[3, 0]` не сортируется, `Float` эмбеддинга равны побитово —
    /// включая `-0.0` (равен `0.0` по `==`, но не по битам) и субнормальное `1e-38`.
    func testZ8_2_speakersRoundTripKeepsOrderAndFloatBits() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let recordingId = try await SpeakersFixtures.makeRecording(temp.database)
        let original = try SpeakersFixtures.twoSpeakersTranscript(recordingId: recordingId)

        let header = try await temp.database.transcriptRepository().save(original)
        let maybeRead = try await temp.database.transcriptRepository().transcript(id: header.id)
        let read = try XCTUnwrap(maybeRead)

        XCTAssertEqual(read.speakers, original.speakers)
        XCTAssertEqual(read.speakers.map(\.cluster), [3, 0], "порядок значения, не по возрастанию")
        let writtenBits = try XCTUnwrap(original.speakers[0].embedding).map(\.bitPattern)
        let readBits = try XCTUnwrap(read.speakers[0].embedding).map(\.bitPattern)
        XCTAssertEqual(readBits, writtenBits, "Float эмбеддинга равны побитово")
        XCTAssertEqual(read.speakers[0].embeddingModelVersion, "wespeaker-1")
        XCTAssertEqual(read.speakers[0].totalMs, 12_345, "totalMs записанный, не сумма сегментов")
    }

    // MARK: - Критерий 3

    func testZ8_3_emptySpeakersAreWrittenAsEmptyArrayNotNull() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let recordingId = try await SpeakersFixtures.makeRecording(temp.database)
        let original = try TestFixtures.transcript(
            recordingId: recordingId, segments: TestFixtures.threeDistinctSegments(prefix: "empty")
        )
        XCTAssertEqual(original.speakers, [])

        let header = try await temp.database.transcriptRepository().save(original)

        XCTAssertEqual(try SpeakersFixtures.speakersJSON(temp.database, header.id), .some("[]"))
        let maybeRead = try await temp.database.transcriptRepository().transcript(id: header.id)
        let read = try XCTUnwrap(maybeRead)
        XCTAssertEqual(read.speakers, [])
        let nullRows = try temp.database.rawRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM transcripts WHERE speakers_json IS NULL")
        }
        XCTAssertEqual(nullRows, 0, "save не пишет NULL")
    }

    // MARK: - Критерий 4

    /// Кластер 7 — ни одного сегмента; реконструкция по сегментам его бы потеряла.
    func testZ8_4_speakerWithoutSegmentsSurvivesRoundTrip() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let recordingId = try await SpeakersFixtures.makeRecording(temp.database)
        let original = try SpeakersFixtures.speakerWithoutSegmentsTranscript(recordingId: recordingId)
        XCTAssertFalse(original.segments.contains { $0.speakerCluster == 7 })

        let header = try await temp.database.transcriptRepository().save(original)
        let maybeRead = try await temp.database.transcriptRepository().transcript(id: header.id)
        let read = try XCTUnwrap(maybeRead)

        XCTAssertEqual(read.speakers, original.speakers)
        XCTAssertTrue(read.speakers.contains { $0.cluster == 7 })
    }

    // MARK: - Критерий 6

    func testZ8_6_unparsableSpeakersJSONIsDataCorrupted() async throws {
        try await assertCorrupted(speakersJSON: "not json")
    }

    /// JSON разбирается, но кластера 0 сегмента в нём нет — `Transcript.init` (C-003,
    /// инвариант 9) отказывает, и отказ сводится к `dataCorrupted` (инвариант 21).
    func testZ8_6_speakersJSONMissingSegmentClusterIsDataCorrupted() async throws {
        try await assertCorrupted(speakersJSON: #"[{"cluster":5,"totalMs":1}]"#)
    }

    private func assertCorrupted(speakersJSON: String, line: UInt = #line) async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let recordingId = try await SpeakersFixtures.makeRecording(temp.database)
        let header = try await temp.database.transcriptRepository().save(
            try SpeakersFixtures.systemChannelWithoutDiarization(recordingId: recordingId)
        )
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE transcripts SET speakers_json = ? WHERE id = ?",
                arguments: [speakersJSON, header.id.uuidString]
            )
        }

        do {
            _ = try await temp.database.transcriptRepository().transcript(id: header.id)
            XCTFail("ожидался dataCorrupted", line: line)
        } catch let StorageError.dataCorrupted(entity, id, _) {
            XCTAssertEqual(entity, "Transcript", line: line)
            XCTAssertEqual(id, header.id.uuidString, line: line)
        }
    }

    // MARK: - Критерий 8

    /// Фикстура Z3а «системный канал без диаризации» (MEE-486/MEE-501) в `main` к моменту
    /// этой работы не слита — критерий проверяется на эквивалентной собственной:
    /// сегменты `system` с кластером 0, `Speaker(0, nil, nil, S)`.
    func testZ8_8_systemChannelWithoutDiarizationRoundTrips() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let recordingId = try await SpeakersFixtures.makeRecording(temp.database)
        let original = try SpeakersFixtures.systemChannelWithoutDiarization(recordingId: recordingId)

        let header = try await temp.database.transcriptRepository().save(original)
        let maybeRead = try await temp.database.transcriptRepository().transcript(id: header.id)
        let read = try XCTUnwrap(maybeRead)

        XCTAssertEqual(read.speakers, original.speakers)
        XCTAssertEqual(read.segments, original.segments)
    }

    /// Сверх критериев: каждая фикстура C-003 из `DomainTestKit` проходит круг целиком.
    func testZ8_everyTranscriptFixtureRoundTripsSpeakers() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let recordingId = try await SpeakersFixtures.makeRecording(temp.database)
        let repository = temp.database.transcriptRepository()
        for fixture in TranscriptFixtures.allFixtures {
            let original = try SpeakersFixtures.rebased(fixture, recordingId: recordingId)
            let header = try await repository.save(original)
            let maybeRead = try await repository.transcript(id: header.id)
            let read = try XCTUnwrap(maybeRead)
            XCTAssertEqual(read.speakers, original.speakers)
        }
    }
}

/// Значения MEE-505 — общие для файлов этого круга.
enum SpeakersFixtures {

    static func makeRecording(_ database: StorageDatabase) async throws -> UUID {
        let recordingId = UUID()
        let layout = FileLayout(root: FileManager.default.temporaryDirectory)
        try await database.recordingRepository(fileLayout: layout).save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        return recordingId
    }

    static func speakersJSON(_ database: StorageDatabase, _ transcriptId: UUID) throws -> String? {
        try database.rawRead { db in
            try String.fetchOne(
                db, sql: "SELECT speakers_json FROM transcripts WHERE id = ?", arguments: [transcriptId.uuidString]
            )
        }
    }

    /// Критерий 2 дословно: `[3, 0]`, эмбеддинг с `-0.0` и `1e-38`.
    static func twoSpeakersTranscript(recordingId: UUID) throws -> Transcript {
        try TestFixtures.transcript(
            recordingId: recordingId,
            segments: [
                TestFixtures.segment(startMs: 0, endMs: 500, text: "ноль", channel: .system, speakerCluster: 0),
                TestFixtures.segment(startMs: 500, endMs: 1_300, text: "три", channel: .system, speakerCluster: 3)
            ],
            speakers: [
                Transcript.Speaker(
                    cluster: 3, embedding: [0.1, -0.0, 1e-38, 0.5],
                    embeddingModelVersion: "wespeaker-1", totalMs: 12_345
                ),
                Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 800)
            ]
        )
    }

    static func speakerWithoutSegmentsTranscript(recordingId: UUID) throws -> Transcript {
        try TestFixtures.transcript(
            recordingId: recordingId,
            segments: [
                TestFixtures.segment(startMs: 0, endMs: 1_000, text: "один", channel: .system, speakerCluster: 1)
            ],
            speakers: [
                Transcript.Speaker(cluster: 1, embedding: nil, embeddingModelVersion: nil, totalMs: 1_000),
                Transcript.Speaker(cluster: 7, embedding: [0.25], embeddingModelVersion: "wespeaker-1", totalMs: 0)
            ]
        )
    }

    /// Эквивалент фикстуры Z3а (MEE-486): `system` без диаризации — все сегменты
    /// системного канала в кластере 0, один `Speaker(0, nil, nil, S)`, `S` — сумма
    /// длительностей (C-011 инвариант 18); плюс сегмент `mic` без кластера.
    static func systemChannelWithoutDiarization(recordingId: UUID) throws -> Transcript {
        try TestFixtures.transcript(
            recordingId: recordingId,
            segments: [
                TestFixtures.segment(startMs: 0, endMs: 1_000, text: "микрофон", channel: .mic),
                TestFixtures.segment(startMs: 1_000, endMs: 2_500, text: "система раз", channel: .system,
                                     speakerCluster: 0),
                TestFixtures.segment(startMs: 3_000, endMs: 4_000, text: "система два", channel: .system,
                                     speakerCluster: 0)
            ],
            speakers: [Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 2_500)]
        )
    }

    /// Та же фикстура на записи, существующей в этой базе (внешний ключ `recording_id`).
    static func rebased(_ fixture: Transcript, recordingId: UUID) throws -> Transcript {
        try Transcript(
            recordingId: recordingId, language: fixture.language, engine: fixture.engine,
            modelVersion: fixture.modelVersion, createdAt: fixture.createdAt,
            segments: fixture.segments, speakers: fixture.speakers
        )
    }
}
