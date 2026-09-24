//  EntityDictionaryTableTests — К32 перечня MEE-189 (инвариант 22, словарь
//  entity/id), владелец: DEV-2.
//
//  К32 просит путь `notFound` НА КАЖДОМ из десяти имён словаря. Не сходится
//  с К28 (уже принят РП в этом же возврате): К28 закрывает список семью
//  методами, бросающими `notFound`, и они называют ровно пять сущностей —
//  Meeting (`setStatus`), Person (`rename`/`setMe`), Connector (`setCursor`/
//  `setSyncOutcome`), MeetingOutput (`markUserEdited`), Segment
//  (`updateSegmentText`). У Recording, Transcript, Job, SpeakerProfile,
//  Setting нет НИ ОДНОГО метода порта, бросающего `notFound`, — К28 это
//  прямо запрещает («восьмой метод, бросающий notFound, инвариант
//  нарушает»). Путь `notFound` реализован и проверен только для этих пяти;
//  для остальных пяти — структурно недостижим, не решаю за контракт.
//  `Setting` — тоже без пути `dataCorrupted`: `value(forKey:)` не разбирает
//  ничего вовсе (К46(iii), принято), значит НИ ОДИН из двух путей у него не
//  достижим ни при каком содержимом колонки.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class EntityDictionaryTableTests: StorageAsyncTestCase {

    // MARK: - Путь notFound (пять из десяти — см. шапку файла)

    func testK32_notFoundPathForFiveApplicableEntities() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetings = temp.database.meetingRepository()
        let persons = temp.database.personRepository()
        let connectors = temp.database.connectorRepository()
        let outputs = temp.database.meetingOutputRepository()
        let transcripts = temp.database.transcriptRepository()

        let meetingId = UUID()
        try await Self.assertNotFound(entity: "Meeting", id: meetingId.uuidString) {
            try await meetings.setStatus(.recording, meetingId: meetingId)
        }
        let personId = UUID()
        try await Self.assertNotFound(entity: "Person", id: personId.uuidString) {
            try await persons.rename(personId: personId, displayName: "x")
        }
        try await Self.assertNotFound(entity: "Connector", id: "absent") {
            try await connectors.setCursor("c", connectorId: "absent")
        }
        let outputId = UUID()
        try await Self.assertNotFound(entity: "MeetingOutput", id: outputId.uuidString) {
            try await outputs.markUserEdited(outputId: outputId, contentMarkdown: "x")
        }
        try await Self.assertNotFound(entity: "Segment", id: "-1") {
            try await transcripts.updateSegmentText(segmentId: -1, text: "x", isUserEdited: true)
        }
    }

    // MARK: - Путь dataCorrupted: формат id, не только имя entity

    /// UUID-keyed сущности: `id` — `UUID.uuidString` верхним регистром, с
    /// дефисами, без фигурных скобок.
    func testK32_dataCorruptedIdFormatIsUppercaseUUIDWithDashes() async throws {
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
        do {
            _ = try await recordings.recording(id: recordingId)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(let entity, let id, _) = error else {
                XCTFail("ожидался dataCorrupted"); return
            }
            XCTAssertEqual(entity, "Recording")
            XCTAssertEqual(id, recordingId.uuidString)
            XCTAssertEqual(id, id.uppercased(), "верхний регистр")
            XCTAssertTrue(id.contains("-"), "с дефисами")
            XCTAssertFalse(id.contains("{"), "без фигурных скобок")
        }
    }

    /// `segments.id` — `INTEGER PRIMARY KEY`: десятичная запись `Int64`, не
    /// шестнадцатеричная и не с ведущими нулями/знаком помимо необходимого.
    func testK32_dataCorruptedIdFormatForSegmentIsDecimalInt64() async throws {
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
        do {
            _ = try await transcripts.segments(transcriptId: header.id)
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(let entity, let id, _) = error else {
                XCTFail("ожидался dataCorrupted"); return
            }
            XCTAssertEqual(entity, "Segment")
            XCTAssertNotNil(Int64(id), "десятичная запись Int64: \(id)")
        }
    }

    /// `ConnectorRecord.id`/`app_settings.key` — ключ как есть, не UUID.
    func testK32_dataCorruptedIdFormatForConnectorIsRawKeyAsIs() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let connectors = temp.database.connectorRepository()
        try await connectors.upsert(ConnectorRecord(
            id: "my-connector-key", type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: "ns", selectedCalendarIds: [], isEnabled: true,
            lastSyncAt: nil, cursor: nil, lastError: nil
        ))
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE connectors SET selected_calendar_ids_json = 'not-json' WHERE id = 'my-connector-key'"
            )
        }
        do {
            _ = try await connectors.all()
            XCTFail("ожидался dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted(let entity, let id, _) = error else {
                XCTFail("ожидался dataCorrupted"); return
            }
            XCTAssertEqual(entity, "Connector")
            XCTAssertEqual(id, "my-connector-key", "ключ как есть, не переписан")
        }
    }

    // MARK: - Оснастка

    private static func assertNotFound(
        entity: String, id: String, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> Void
    ) async throws {
        do {
            try await body()
            XCTFail("ожидался notFound", file: file, line: line)
        } catch let error as StorageError {
            guard case .notFound(let namedEntity, let namedId) = error else {
                XCTFail("ожидался notFound, получено \(error)", file: file, line: line); return
            }
            XCTAssertEqual(namedEntity, entity, file: file, line: line)
            XCTAssertEqual(namedId, id, file: file, line: line)
        }
    }
}
