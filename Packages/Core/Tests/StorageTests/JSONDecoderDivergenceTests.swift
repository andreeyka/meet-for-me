//  JSONDecoderDivergenceTests — К43 перечня MEE-189 (инвариант 27, вектор 1),
//  владелец: DEV-2. recordings.manifest_json здесь; words_json/payload_json/
//  connectors — в `JSONDecoderDivergenceExtraTests.swift` (тот же критерий,
//  разведён по объёму `type_body_length`, не по смыслу).
//
//  Ответ наблюдаем без знания, какой именно декодер откажет: чтение отказывает
//  на всех входах, отказ сведён к `StorageError.dataCorrupted` с настоящими
//  `entity`/`id` разбитой строки и текстом причины (`messageContains`), а не
//  только фактом отказа. Поля с `decodeBounded`, которыми это доказывается —
//  `RecordingManifest.schemaVersion`/`Marker.atMs` (manifest_json) и
//  `Transcript.Word.startMs/endMs` (words_json) — по возврату РП.
//
//  Вход «дробный литерал в целом поле» заменён на «целое вне безопасного
//  диапазона» (2^53, §0.2 п. 9) — IR-115 закрыт разъяснением архитектора
//  (C-001 v12 §0.4, буква готовится в MEE-337): "1.0" в целом поле законна,
//  `DomainJSON` на дробном литерале с нулевой дробной частью не отличается
//  от стандартного `JSONDecoder`, и прежний вход ничего не проверял.
//
//  Шаблон применим не ко всем четырём колонкам целиком (подробности — шапка
//  `JSONDecoderDivergenceExtraTests.swift`): `jobs.payload_json` не несёт ни
//  одного числового поля, `connectors.selected_calendar_ids_json` — плоский
//  `[String]` без числовых полей и без объектных ключей на верхнем уровне.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class JSONDecoderDivergenceTests: StorageAsyncTestCase {

    // MARK: - recordings.manifest_json (RecordingManifest.schemaVersion)

    func testK43_manifestJSONRejectsNonFiniteSchemaVersion() async throws {
        try await Self.assertManifestRejected(schemaVersionText: "1e400")
    }

    /// IR-115 закрыт разъяснением архитектора (C-001 v12 §0.4, буква в MEE-337
    /// готовится аналитиком): "1.0" в целом поле — законная 1, `DomainJSON`
    /// на дробном литерале с нулевой дробной частью верен. Вход К43 «дробный
    /// литерал» заменён на 2^53 (§0.2 п. 9): `RecordingManifest.Marker.atMs`
    /// вне безопасного диапазона (`-(2^53-1)…(2^53-1)`) — стандартный
    /// `JSONDecoder` число 9007199254740992 в `Int` принимает без вопросов
    /// (показано зондом ниже, без похода в БД), `DomainJSON` отказывает.
    func testK43_manifestJSONRejectsIntegerBeyondSafeRange() async throws {
        struct AtMsProbe: Decodable { let atMs: Int }
        let probe = try JSONDecoder().decode(
            AtMsProbe.self, from: Data(#"{"atMs":9007199254740992}"#.utf8)
        )
        XCTAssertEqual(probe.atMs, 9_007_199_254_740_992, "стандартный JSONDecoder принимает 2^53 как Int")

        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let layout = FileLayout(root: temp.directory)
        let recordings = temp.database.recordingRepository(fileLayout: layout)
        let recordingId = UUID()
        let manifest = try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: TestFixtures.epoch, endedAt: nil,
            tracks: [try RecordingManifest.Track(
                channel: .mic, fileName: "audio-mic.caf", sampleRate: 16_000, channelCount: 1, format: "pcm-caf"
            )],
            markers: [try RecordingManifest.Marker(kind: .pause, atMs: 0, detail: nil)],
            capturedProcesses: [], captureGroupKey: nil, inputDevices: [], discontinuities: [], isFinalized: false
        )
        try await recordings.save(RecordingRecord(manifest: manifest, status: .recording))

        let validJSON = try Self.currentManifestJSON(recordingId: recordingId, database: temp.database)
        let broken = validJSON.replacingOccurrences(of: "\"atMs\":0", with: "\"atMs\":9007199254740992")
        try XCTUnwrap(broken != validJSON ? broken : nil, "\"atMs\":0 не найден в сериализации манифеста")
        try Self.writeManifestJSON(broken, recordingId: recordingId, database: temp.database)

        try await Self.assertDataCorrupted(
            entity: "Recording", id: recordingId.uuidString, messageContains: "значение вне диапазона §0.2 п. 9"
        ) {
            try await recordings.recording(id: recordingId)
        }
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

    static func assertDataCorrupted<T>(
        entity: String, id: String, messageContains: String? = nil,
        file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> T
    ) async throws {
        do {
            _ = try await body()
            XCTFail("ожидался dataCorrupted", file: file, line: line)
        } catch let error as StorageError {
            guard case .dataCorrupted(let gotEntity, let gotId, let message) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)", file: file, line: line); return
            }
            XCTAssertEqual(gotEntity, entity, "entity словаря ошибок", file: file, line: line)
            XCTAssertEqual(gotId, id, "id — реальной строки, не заглушка", file: file, line: line)
            // Причина отказа видна в message, не только факт dataCorrupted —
            // не даёт входу с двумя одновременными нарушениями молча
            // доказывать не то, что заявлено (находка РП по testK43_words
            // JSONRejectsIntegerBeyondSafeRange, разведён в …ExtraTests.swift).
            if let messageContains {
                XCTAssertTrue(
                    message.contains(messageContains),
                    "message несёт причину отказа (\(messageContains)): \(message)", file: file, line: line
                )
            }
        }
    }
}
