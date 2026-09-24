//  JSONDecoderDivergenceExtraTests — К43 перечня MEE-189 (инвариант 27,
//  вектор 1), владелец: DEV-2. Разведён с `JSONDecoderDivergenceTests.swift`
//  по объёму (`type_body_length`) — не по смыслу: words_json/payload_json/
//  connectors, а не manifest_json. `assertDataCorrupted` — общий, объявлен
//  `internal` в файле-соседе, не дублирован.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class JSONDecoderDivergenceExtraTests: StorageAsyncTestCase {

    // MARK: - segments.words_json (Transcript.Word.startMs/endMs)

    func testK43_wordsJSONRejectsNonFiniteStartMs() async throws {
        try await Self.assertWordsJSONRejected(#"[{"startMs":1e400,"endMs":10,"text":"x"}]"#)
    }

    /// Тот же вход К43 после закрытия IR-115 (см. testK43_manifestJSONRejects
    /// IntegerBeyondSafeRange в `JSONDecoderDivergenceTests.swift`) — 2^53
    /// вместо дробного литерала, на поле `Transcript.Word.startMs` (тоже
    /// `decodeBounded`, §0.2 п. 9).
    ///
    /// СТРОКА-находка РП (не решаю сама, уже исправлено): `endMs` тоже 2^53,
    /// не `10`, — с `endMs: 10` вход нёс ВТОРОЕ нарушение (`endMs < startMs`,
    /// инв. 4 `Transcript.Word`) одновременно с выходом за §0.2 п. 9, и отказ
    /// мог бы прийти по любому из двух, не доказывая именно безопасный
    /// диапазон. Равные `startMs`/`endMs` держат слово корректным по
    /// длительности (не отрицательным) и нарушают только п. 9.
    func testK43_wordsJSONRejectsIntegerBeyondSafeRange() async throws {
        struct StartMsProbe: Decodable { let startMs: Int }
        let probe = try JSONDecoder().decode(
            StartMsProbe.self, from: Data(#"{"startMs":9007199254740992}"#.utf8)
        )
        XCTAssertEqual(probe.startMs, 9_007_199_254_740_992, "стандартный JSONDecoder принимает 2^53 как Int")

        try await Self.assertWordsJSONRejected(
            #"[{"startMs":9007199254740992,"endMs":9007199254740992,"text":"x"}]"#,
            messageContains: "значение вне диапазона §0.2 п. 9"
        )
    }

    func testK43_wordsJSONRejectsDuplicateKey() async throws {
        try await Self.assertWordsJSONRejected(#"[{"startMs":0,"endMs":10,"endMs":10,"text":"x"}]"#)
    }

    private static func assertWordsJSONRejected(
        _ brokenWordsJSON: String, messageContains: String? = nil
    ) async throws {
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
        try await JSONDecoderDivergenceTests.assertDataCorrupted(
            entity: "Transcript", id: header.id.uuidString, messageContains: messageContains
        ) {
            try await transcripts.transcript(id: header.id)
        }
    }

    // MARK: - jobs.payload_json (JobPayload) — только дублирующийся ключ (см. шапку соседнего файла)

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
        try await JSONDecoderDivergenceTests.assertDataCorrupted(entity: "Job", id: job.id.uuidString) {
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
        try await JSONDecoderDivergenceTests.assertDataCorrupted(entity: "Connector", id: "k43-dup") {
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
}
