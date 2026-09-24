//  PortsDataCorruptedTests — К29 перечня MEE-189 (инвариант 21, восемь портов
//  §5), владелец: DEV-2.
//
//  `SettingsRepository.value(forKey:)` не входит: колонка `app_settings.value`
//  — байты `Data`, которые `storage` не разбирает вовсе (К46(iii), уже
//  принято) — `dataCorrupted` на этом методе структурно не возникает ни при
//  каком содержимом колонки. Строка для аналитика, не решаю сама: К29 просит
//  «по одному... на каждый из восьми портов», но у `Settings` для этого нет
//  ни одного разбираемого поля.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class PortsDataCorruptedTests: StorageAsyncTestCase {

    // MARK: - Meeting: meeting(id:) — битый dedup_key

    func testK29_meetingGivesDataCorruptedOnBrokenDedupKey() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetings = temp.database.meetingRepository()
        let event = try TestFixtures.meetingEvent()
        try await meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: []))
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE meetings SET dedup_key = 'not-json' WHERE id = ?", arguments: [event.id.uuidString]
            )
        }
        try await Self.assertDataCorrupted(entity: "Meeting") { try await meetings.meeting(id: event.id) }
    }

    // MARK: - Recording: recording(id:) — битый manifest_json

    func testK29_recordingGivesDataCorruptedOnBrokenManifestJSON() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        let recordingId = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE recordings SET manifest_json = 'not-json' WHERE id = ?",
                arguments: [recordingId.uuidString]
            )
        }
        try await Self.assertDataCorrupted(entity: "Recording") { try await recordings.recording(id: recordingId) }
    }

    // MARK: - Transcript: transcript(id:) — битый words_json

    func testK29_transcriptGivesDataCorruptedOnBrokenWordsJSON() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        let transcripts = temp.database.transcriptRepository()
        let recordingId = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let header = try await transcripts.save(try TestFixtures.transcript(
            recordingId: recordingId, segments: [try TestFixtures.segment(startMs: 0, endMs: 10, text: "x")]
        ))
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE segments SET words_json = 'not-json' WHERE transcript_id = ?",
                arguments: [header.id.uuidString]
            )
        }
        try await Self.assertDataCorrupted(entity: "Transcript") { try await transcripts.transcript(id: header.id) }
    }

    // MARK: - Person: me() — id не разбирается в UUID
    //
    // `person(id:)`/`persons(ids:)` ищут по УЖЕ переданному валидному UUID и
    // потому в принципе не могут наткнуться на строку, чей `id` не разбирается
    // в UUID, — такую строку нечем запросить типизированным параметром.
    // `me()` находит строку сканом по `is_me = 1`, без готового id на входе,
    // и потому единственный подходящий читающий метод порта для этого входа.

    func testK29_personGivesDataCorruptedOnUnparsableId() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let persons = temp.database.personRepository()
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "INSERT INTO persons (id, display_name, is_me, created_at, updated_at) "
                    + "VALUES ('not-a-uuid', 'x', 1, 0, 0)"
            )
        }
        try await Self.assertDataCorrupted(entity: "Person") { try await persons.me() }
    }

    // MARK: - SpeakerProfile: profile(...) — рассогласованный embedding

    func testK29_speakerProfileGivesDataCorruptedOnMismatchedEmbeddingLength() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let persons = temp.database.personRepository()
        let profiles = temp.database.speakerProfileRepository()
        let personId = try await persons.upsert(displayName: "x", emails: ["x@example.com"])
        try temp.database.rawWrite { db in
            try db.execute(
                sql: """
                INSERT INTO speaker_profiles
                    (person_id, embedding, embedding_dim, model_version, sample_count, updated_at)
                VALUES (?, ?, 192, '1.0', 0, 0)
                """,
                arguments: [personId.uuidString, Data(repeating: 0, count: 4)]
            )
        }
        try await Self.assertDataCorrupted(entity: "SpeakerProfile") {
            try await profiles.profile(personId: personId, modelVersion: "1.0")
        }
    }

    // MARK: - Connector: all() — битый selected_calendar_ids_json

    func testK29_connectorGivesDataCorruptedOnBrokenSelectedCalendarIdsJSON() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let connectors = temp.database.connectorRepository()
        try await connectors.upsert(ConnectorRecord(
            id: "c1", type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: "ns", selectedCalendarIds: [], isEnabled: true,
            lastSyncAt: nil, cursor: nil, lastError: nil
        ))
        try temp.database.rawWrite { db in
            try db.execute(sql: "UPDATE connectors SET selected_calendar_ids_json = 'not-json' WHERE id = 'c1'")
        }
        try await Self.assertDataCorrupted(entity: "Connector") { try await connectors.all() }
    }

    // MARK: - MeetingOutput: outputs(meetingId:) — недопустимое значение kind

    func testK29_meetingOutputGivesDataCorruptedOnInvalidKind() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetings = temp.database.meetingRepository()
        let outputs = temp.database.meetingOutputRepository()
        let event = try TestFixtures.meetingEvent()
        try await meetings.save(MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: []))
        let outputId = UUID()
        try await outputs.save(MeetingOutput(
            id: outputId, meetingId: event.id, kind: .summary, engine: "e", modelVersion: "1.0",
            promptVersion: "1.0", contentMarkdown: "x", structuredJson: nil,
            createdAt: TestFixtures.epoch, isUserEdited: false
        ))
        try temp.database.rawWrite { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(
                sql: "UPDATE meeting_outputs SET kind = 'bogus' WHERE id = ?", arguments: [outputId.uuidString]
            )
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }
        try await Self.assertDataCorrupted(entity: "MeetingOutput") {
            try await outputs.outputs(meetingId: event.id)
        }
    }

    // MARK: - Оснастка

    private static func assertDataCorrupted<T>(
        entity: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
    ) async throws {
        do {
            _ = try await body()
            XCTFail("ожидался dataCorrupted", file: file, line: line)
        } catch let error as StorageError {
            guard case .dataCorrupted(let named, _, _) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)", file: file, line: line); return
            }
            XCTAssertEqual(named, entity, file: file, line: line)
        }
    }
}
