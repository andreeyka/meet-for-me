//  JSONDecoderDivergenceTests — К43 перечня MEE-189 (инвариант 27, вектор 1),
//  владелец: DEV-2.
//
//  Ответ наблюдаем без знания, какой именно декодер откажет: чтение отказывает
//  на всех входах, отказ сведён к `StorageError.dataCorrupted` с настоящими
//  `entity`/`id` разбитой строки, а не только фактом отказа. Поля с
//  `decodeBounded`/`decodeFiniteIfPresent`, которыми это доказывается —
//  `RecordingManifest.schemaVersion` (manifest_json) и `Transcript.Word.
//  startMs/endMs` (words_json) — по возврату РП.
//
//  Шаблон применим не ко всем четырём колонкам целиком:
//  - `jobs.payload_json` (`JobPayload`) не несёт ни одного числового поля —
//    только `UUID`/`String` — «1e400» и «дробный литерал в целом поле»
//    здесь не сконструировать буквально; проверен только дублирующийся ключ.
//  - `connectors.selected_calendar_ids_json` (`[String]`) — плоский массив без
//    объектных ключей и без числовых полей: «1e400» и «дробный литерал в целом
//    поле» по-прежнему не сконструировать буквально, но `assertNoDuplicateKeys`
//    (`DomainJSONDuplicateKeys.swift`) — байтовый проход по ВСЕМ фигурным
//    скобкам документа, а не по типу верхнего уровня, поэтому дублирующийся
//    ключ внутри вложенного объекта отказывает и здесь (восьмой вход дельты О),
//    даже если сам верхний уровень колонки — массив, а не объект.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class JSONDecoderDivergenceTests: StorageAsyncTestCase {

    // MARK: - recordings.manifest_json (RecordingManifest.schemaVersion)

    func testK43_manifestJSONRejectsNonFiniteSchemaVersion() async throws {
        try await Self.assertManifestRejected(schemaVersionText: "1e400")
    }

    func testK43_manifestJSONRejectsFractionalSchemaVersion() async throws {
        // "1.0", не "3.5"/"1.5" (по возврату РП): на явно дробном значении
        // отказал бы любой декодер, приводимый к Int, — такой вход не отличает
        // DomainJSON от чужого декодера. "1.0" целочисленно по значению, но
        // записано литералом с плавающей точкой.
        try await Self.assertManifestRejected(schemaVersionText: "1.0")
    }

    func testK43_manifestJSONRejectsDuplicateTopLevelKey() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        let recordingId = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let validJSON = try Self.currentManifestJSON(recordingId: recordingId, database: temp.database)
        let duplicated = Self.duplicateTopLevelKeys(validJSON)
        try Self.writeManifestJSON(duplicated, recordingId: recordingId, database: temp.database)
        try await Self.assertDataCorrupted(entity: "Recording", id: recordingId.uuidString) {
            try await recordings.recording(id: recordingId)
        }
    }

    private static func assertManifestRejected(schemaVersionText: String) async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        let recordingId = UUID()
        try await recordings.save(RecordingRecord(
            manifest: try TestFixtures.recordingManifest(recordingId: recordingId), status: .recording
        ))
        let validJSON = try Self.currentManifestJSON(recordingId: recordingId, database: temp.database)
        let broken = try Self.replacingSchemaVersion(in: validJSON, with: schemaVersionText)
        try Self.writeManifestJSON(broken, recordingId: recordingId, database: temp.database)
        try await Self.assertDataCorrupted(entity: "Recording", id: recordingId.uuidString) {
            try await recordings.recording(id: recordingId)
        }
    }

    private static func currentManifestJSON(recordingId: UUID, database: StorageDatabase) throws -> String {
        try database.rawRead { db in
            try String.fetchOne(
                db, sql: "SELECT manifest_json FROM recordings WHERE id = ?", arguments: [recordingId.uuidString]
            ) ?? ""
        }
    }

    private static func writeManifestJSON(_ json: String, recordingId: UUID, database: StorageDatabase) throws {
        try database.rawWrite { db in
            try db.execute(
                sql: "UPDATE recordings SET manifest_json = ? WHERE id = ?", arguments: [json, recordingId.uuidString]
            )
        }
    }

    private static func replacingSchemaVersion(in json: String, with replacement: String) throws -> String {
        let needle = "\"schemaVersion\":\(RecordingManifest.currentSchemaVersion)"
        let replaced = json.replacingOccurrences(of: needle, with: "\"schemaVersion\":\(replacement)")
        try XCTUnwrap(replaced != json ? replaced : nil, "\(needle) не найден в сериализации манифеста")
        return replaced
    }

    // MARK: - segments.words_json (Transcript.Word.startMs/endMs)

    func testK43_wordsJSONRejectsNonFiniteStartMs() async throws {
        try await Self.assertWordsJSONRejected(#"[{"startMs":1e400,"endMs":10,"text":"x"}]"#)
    }

    func testK43_wordsJSONRejectsFractionalStartMs() async throws {
        // "1.0", не "1.5" (по возврату РП) — тот же довод, что у schemaVersion выше.
        try await Self.assertWordsJSONRejected(#"[{"startMs":1.0,"endMs":10,"text":"x"}]"#)
    }

    func testK43_wordsJSONRejectsDuplicateKey() async throws {
        try await Self.assertWordsJSONRejected(#"[{"startMs":0,"endMs":10,"endMs":10,"text":"x"}]"#)
    }

    private static func assertWordsJSONRejected(_ brokenWordsJSON: String) async throws {
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
                sql: "UPDATE segments SET words_json = ? WHERE transcript_id = ?",
                arguments: [brokenWordsJSON, header.id.uuidString]
            )
        }
        try await Self.assertDataCorrupted(entity: "Transcript", id: header.id.uuidString) {
            try await transcripts.transcript(id: header.id)
        }
    }

    // MARK: - jobs.payload_json (JobPayload) — только дублирующийся ключ (см. шапку)

    func testK43_payloadJSONRejectsDuplicateTopLevelKey() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let job = TestFixtures.job(payload: .transcode(recordingId: UUID()))
        try await jobs.insert(job)
        let validJSON = try temp.database.rawRead { db in
            try String.fetchOne(
                db, sql: "SELECT payload_json FROM jobs WHERE id = ?", arguments: [job.id.uuidString]
            ) ?? ""
        }
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE jobs SET payload_json = ? WHERE id = ?",
                arguments: [Self.duplicateTopLevelKeys(validJSON), job.id.uuidString]
            )
        }
        try await Self.assertDataCorrupted(entity: "Job", id: job.id.uuidString) {
            try await jobs.job(id: job.id)
        }
    }

    // MARK: - connectors.selected_calendar_ids_json — дублирующийся ключ (восьмой вход дельты О)

    func testK43_selectedCalendarIdsJSONRejectsDuplicateKey() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let connectors = temp.database.connectorRepository()
        try await connectors.upsert(ConnectorRecord(
            id: "k43-dup", type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: "ns", selectedCalendarIds: ["cal-1"], isEnabled: true,
            lastSyncAt: nil, cursor: nil, lastError: nil
        ))
        // Колонка сама по себе — плоский `[String]`, без единого объектного
        // ключа, но `assertNoDuplicateKeys` сканирует байты документа целиком,
        // а не структуру целевого типа: объект с повторённым ключом где угодно
        // внутри массива отказывает раньше, чем `[String].init(from:)` вообще
        // заметит несовпадение формы.
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE connectors SET selected_calendar_ids_json = ? WHERE id = 'k43-dup'",
                arguments: [#"["cal-1",{"dup":1,"dup":2}]"#]
            )
        }
        try await Self.assertDataCorrupted(entity: "Connector", id: "k43-dup") {
            try await connectors.all()
        }
    }

    // MARK: - Оснастка

    /// Клонирует все ключи верхнего уровня валидного JSON-объекта `{...}` в
    /// один буквально дублирующийся набор — `assertNoDuplicateKeys` обязан
    /// отказать на первом же повторе, независимо от имён конкретных полей.
    private static func duplicateTopLevelKeys(_ json: String) -> String {
        let inner = json.dropFirst().dropLast()
        return "{\(inner),\(inner)}"
    }

    private static func assertDataCorrupted<T>(
        entity: String, id: String, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> T
    ) async throws {
        do {
            _ = try await body()
            XCTFail("ожидался dataCorrupted", file: file, line: line)
        } catch let error as StorageError {
            guard case .dataCorrupted(let gotEntity, let gotId, _) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)", file: file, line: line); return
            }
            XCTAssertEqual(gotEntity, entity, "entity словаря ошибок", file: file, line: line)
            XCTAssertEqual(gotId, id, "id — реальной строки, не заглушка", file: file, line: line)
        }
    }
}
