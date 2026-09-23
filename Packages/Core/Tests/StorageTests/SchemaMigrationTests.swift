//  SchemaMigrationTests — К1—К6 перечня MEE-189 (группа A), владелец: DEV-2.
//
//  Ожидаемые значения переписаны из C-010 (MEE-18) v7 §3 независимо от
//  `Migrations.swift` — по тексту контракта, а не по своей же миграции (иначе
//  описка DDL повторилась бы в тесте тем же способом и осталась бы незамеченной).

import XCTest
import GRDB
@testable import Storage

final class SchemaMigrationTests: StorageAsyncTestCase {

    // MARK: - К1

    func testK1_foreignKeysOnPragmaAndInPractice() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }

        let snapshots = try temp.database.poolConnectionPragmas(readerCount: 2)
        XCTAssertEqual(snapshots.count, 3, "писатель + два читателя — не одно соединение")
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.foreignKeys, 1)
        }

        // Отдельное утверждение К1: ключи не только объявлены, но и действуют.
        XCTAssertThrowsError(
            try temp.database.rawWrite { db in
                try db.execute(
                    sql: "INSERT INTO person_emails (email, person_id) VALUES (?, ?)",
                    arguments: ["ghost@example.com", UUID().uuidString]
                )
            }
        )
    }

    // MARK: - К2

    func testK2_walAndSynchronousOnEveryConnectionAndFilesOnDisk() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }

        let snapshots = try temp.database.poolConnectionPragmas(readerCount: 2)
        XCTAssertEqual(snapshots.count, 3)
        for snapshot in snapshots {
            XCTAssertEqual(snapshot.journalMode, "wal")
            XCTAssertEqual(snapshot.synchronous, 1, "NORMAL")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.databaseURL.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.databaseURL.path + "-shm"))
    }

    // MARK: - К3

    func testK3_schemaCompositionMatchesDDL() throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }

        try temp.database.rawRead { db in
            // Четырнадцать таблиц.
            let tableNames = try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ).sorted()
            XCTAssertEqual(tableNames, Self.expectedTables.sorted())

            // Виртуальная таблица FTS5.
            let virtualTableSQL = try String.fetchOne(
                db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'segments_fts'"
            )
            XCTAssertNotNil(virtualTableSQL)
            XCTAssertTrue(virtualTableSQL?.contains("fts5") == true)

            // Тринадцать индексов, из них три UNIQUE и два из трёх частичные (WHERE).
            let indexRows = try Row.fetchAll(
                db, sql: "SELECT name, sql FROM sqlite_master WHERE type = 'index' AND name NOT LIKE 'sqlite_%'"
            )
            let indexNames = Set(indexRows.map { $0["name"] as String })
            XCTAssertEqual(indexNames, Set(Self.expectedIndexes))
            let uniqueIndexes = indexRows.filter { ($0["sql"] as String? ?? "").contains("UNIQUE") }
            XCTAssertEqual(Set(uniqueIndexes.map { $0["name"] as String }), Set(Self.expectedUniqueIndexes))
            let partialUnique = uniqueIndexes.filter { ($0["sql"] as String? ?? "").contains("WHERE") }
            XCTAssertEqual(partialUnique.count, 2)

            // Три триггера FTS.
            let triggerNames = Set(try String.fetchAll(
                db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger'"
            ))
            XCTAssertEqual(triggerNames, Set(Self.expectedTriggers))

            // По каждой таблице — имена колонок, объявленные типы, NOT NULL, DEFAULT.
            for (table, expectedColumns) in Self.expectedColumns {
                let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                XCTAssertEqual(columns.count, expectedColumns.count, "число колонок \(table)")
                for (row, expected) in zip(columns, expectedColumns) {
                    XCTAssertEqual(row["name"] as String, expected.name, "\(table).\(expected.name): имя")
                    XCTAssertEqual(
                        (row["type"] as String).uppercased(), expected.type, "\(table).\(expected.name): тип"
                    )
                    let notNull = (row["notnull"] as Int) != 0
                    XCTAssertEqual(notNull, expected.notNull, "\(table).\(expected.name): NOT NULL")
                    let defaultValue = row["dflt_value"] as String?
                    XCTAssertEqual(defaultValue, expected.defaultValue, "\(table).\(expected.name): DEFAULT")
                }
            }

            // Все четырнадцать CHECK DDL — по числу вхождений `CHECK` в текстах создания таблиц.
            let createTableSQL = try String.fetchAll(
                db, sql: "SELECT sql FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ).joined()
            let checkCount = createTableSQL.components(separatedBy: "CHECK").count - 1
            XCTAssertEqual(checkCount, 14)
        }
    }

    // MARK: - К4

    func testK4_migrationDoesNotReapplyAndKeepsData() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }

        try temp.database.rawWrite { db in
            try db.execute(
                sql: "INSERT INTO app_settings (key, value) VALUES (?, ?)",
                arguments: ["k", "\"v\""]
            )
        }

        // Повторная инициализация того же файла.
        let reopened = try StorageDatabase(path: temp.databaseURL)

        let appliedCount = try reopened.rawRead { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?", arguments: ["v1-slice1"]
            ) ?? 0
        }
        XCTAssertEqual(appliedCount, 1)

        let value = try reopened.rawRead { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: ["k"])
        }
        XCTAssertEqual(value, "\"v\"")
    }

    // MARK: - К5 (грепом по исходникам — не требует запуска базы)

    func testK5_noEraseDatabaseOnSchemaChangeTrueOutsideDebug() throws {
        let sourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // StorageTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("Sources/Storage")
        let enumerator = FileManager.default.enumerator(at: sourcesURL, includingPropertiesForKeys: nil)
        var violations: [String] = []
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.contains("eraseDatabaseOnSchemaChange = true"), !text.contains("#if DEBUG") {
                violations.append(file.lastPathComponent)
            }
        }
        XCTAssertTrue(violations.isEmpty, "eraseDatabaseOnSchemaChange=true вне отладочной сборки: \(violations)")
    }

    // MARK: - К6

    func testK6_migrationCompletesBeforeFirstRepositoryCall() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }

        // Счётчик порядка через Ш7: если бы миграция не завершилась к этому моменту,
        // чтение `sqlite_master` не увидело бы ни одной из четырнадцати таблиц.
        let tableCount = try temp.database.rawRead { db in
            try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
            ) ?? 0
        }
        XCTAssertEqual(tableCount, Self.expectedTables.count)

        let repository = temp.database.meetingRepository()
        let result = try await repository.meeting(id: UUID())
        XCTAssertNil(result)
    }

    // MARK: - Ожидаемые значения (независимая транскрипция C-010 v7 §3)

    private struct ExpectedColumn {
        let name: String
        let type: String
        let notNull: Bool
        let defaultValue: String?

        init(_ name: String, _ type: String, notNull: Bool = false, defaultValue: String? = nil) {
            self.name = name
            self.type = type
            self.notNull = notNull
            self.defaultValue = defaultValue
        }
    }

    private static let expectedTables = [
        "persons", "person_emails", "person_name_forms", "meetings", "meeting_sources",
        "attendees", "recordings", "transcripts", "segments", "speaker_profiles",
        "jobs", "connectors", "meeting_outputs", "app_settings",
    ]

    private static let expectedIndexes = [
        "idx_persons_me", "idx_person_emails_person", "idx_person_name_forms_form",
        "idx_meetings_dedup", "idx_meetings_start", "idx_meeting_sources_meeting",
        "idx_recordings_meeting", "idx_transcripts_recording", "idx_segments_transcript",
        "idx_segments_person", "idx_jobs_claim", "idx_jobs_dedup", "idx_meeting_outputs_meeting",
    ]

    private static let expectedUniqueIndexes = ["idx_persons_me", "idx_meetings_dedup", "idx_jobs_dedup"]

    private static let expectedTriggers = ["segments_fts_ai", "segments_fts_ad", "segments_fts_au"]

    private static let expectedColumns: [(String, [ExpectedColumn])] = [
        ("persons", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("display_name", "TEXT", notNull: true),
            ExpectedColumn("is_me", "INTEGER", notNull: true, defaultValue: "0"),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true),
        ]),
        ("person_emails", [
            ExpectedColumn("email", "TEXT", notNull: true),
            ExpectedColumn("person_id", "TEXT", notNull: true),
        ]),
        ("person_name_forms", [
            ExpectedColumn("id", "INTEGER"),
            ExpectedColumn("person_id", "TEXT", notNull: true),
            ExpectedColumn("form", "TEXT", notNull: true),
            ExpectedColumn("kind", "TEXT", notNull: true),
        ]),
        ("meetings", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("title", "TEXT", notNull: true),
            ExpectedColumn("start_at", "INTEGER", notNull: true),
            ExpectedColumn("end_at", "INTEGER", notNull: true),
            ExpectedColumn("time_zone", "TEXT", notNull: true),
            ExpectedColumn("is_all_day", "INTEGER", notNull: true),
            ExpectedColumn("is_cancelled", "INTEGER", notNull: true),
            ExpectedColumn("provider", "TEXT"),
            ExpectedColumn("join_url", "TEXT"),
            ExpectedColumn("conference_meeting_id", "TEXT"),
            ExpectedColumn("conference_passcode", "TEXT"),
            ExpectedColumn("organizer_person_id", "TEXT"),
            ExpectedColumn("location", "TEXT"),
            ExpectedColumn("body_text", "TEXT"),
            ExpectedColumn("dedup_key", "TEXT"),
            ExpectedColumn("status", "TEXT", notNull: true),
            ExpectedColumn("last_modified", "INTEGER", notNull: true),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true),
        ]),
        ("meeting_sources", [
            ExpectedColumn("source_connector_id", "TEXT", notNull: true),
            ExpectedColumn("external_id", "TEXT", notNull: true),
            ExpectedColumn("meeting_id", "TEXT", notNull: true),
            ExpectedColumn("ical_uid", "TEXT"),
            ExpectedColumn("last_modified", "INTEGER", notNull: true),
        ]),
        ("attendees", [
            ExpectedColumn("meeting_id", "TEXT", notNull: true),
            ExpectedColumn("person_id", "TEXT", notNull: true),
            ExpectedColumn("response_status", "TEXT", notNull: true),
            ExpectedColumn("is_optional", "INTEGER", notNull: true),
        ]),
        ("recordings", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("meeting_id", "TEXT"),
            ExpectedColumn("directory_name", "TEXT", notNull: true),
            ExpectedColumn("started_at", "INTEGER", notNull: true),
            ExpectedColumn("ended_at", "INTEGER"),
            ExpectedColumn("manifest_json", "TEXT", notNull: true),
            ExpectedColumn("is_finalized", "INTEGER", notNull: true),
            ExpectedColumn("status", "TEXT", notNull: true),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true),
        ]),
        ("transcripts", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("recording_id", "TEXT", notNull: true),
            ExpectedColumn("file_index", "INTEGER", notNull: true),
            ExpectedColumn("engine", "TEXT", notNull: true),
            ExpectedColumn("model_version", "TEXT", notNull: true),
            ExpectedColumn("language", "TEXT", notNull: true),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
        ]),
        ("segments", [
            ExpectedColumn("id", "INTEGER"),
            ExpectedColumn("transcript_id", "TEXT", notNull: true),
            ExpectedColumn("start_ms", "INTEGER", notNull: true),
            ExpectedColumn("end_ms", "INTEGER", notNull: true),
            ExpectedColumn("channel", "TEXT", notNull: true),
            ExpectedColumn("cluster", "INTEGER"),
            ExpectedColumn("person_id", "TEXT"),
            ExpectedColumn("speaker_confidence", "REAL"),
            ExpectedColumn("attribution_source", "TEXT"),
            ExpectedColumn("text", "TEXT", notNull: true),
            ExpectedColumn("text_original", "TEXT"),
            ExpectedColumn("text_confidence", "REAL"),
            ExpectedColumn("words_json", "TEXT", notNull: true),
            ExpectedColumn("is_user_edited", "INTEGER", notNull: true, defaultValue: "0"),
        ]),
        ("speaker_profiles", [
            ExpectedColumn("id", "INTEGER"),
            ExpectedColumn("person_id", "TEXT", notNull: true),
            ExpectedColumn("embedding", "BLOB", notNull: true),
            ExpectedColumn("embedding_dim", "INTEGER", notNull: true),
            ExpectedColumn("model_version", "TEXT", notNull: true),
            ExpectedColumn("sample_count", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true),
        ]),
        ("jobs", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("type", "TEXT", notNull: true),
            ExpectedColumn("payload_json", "TEXT", notNull: true),
            ExpectedColumn("status", "TEXT", notNull: true),
            ExpectedColumn("priority", "INTEGER", notNull: true),
            ExpectedColumn("attempts", "INTEGER", notNull: true, defaultValue: "0"),
            ExpectedColumn("max_attempts", "INTEGER", notNull: true),
            ExpectedColumn("run_after", "INTEGER", notNull: true),
            ExpectedColumn("requires_ac_power", "INTEGER", notNull: true, defaultValue: "0"),
            ExpectedColumn("forbid_while_recording", "INTEGER", notNull: true, defaultValue: "0"),
            ExpectedColumn("max_thermal_pressure", "TEXT", notNull: true),
            ExpectedColumn("requires_profile_ready", "TEXT"),
            ExpectedColumn("dedup_key", "TEXT"),
            ExpectedColumn("lease_expires_at", "INTEGER"),
            ExpectedColumn("attempt_started_at", "INTEGER"),
            ExpectedColumn("last_error", "TEXT"),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("updated_at", "INTEGER", notNull: true),
        ]),
        ("connectors", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("type", "TEXT", notNull: true),
            ExpectedColumn("plugin_id", "TEXT"),
            ExpectedColumn("settings_json", "TEXT", notNull: true),
            ExpectedColumn("keychain_namespace", "TEXT", notNull: true),
            ExpectedColumn("selected_calendar_ids_json", "TEXT", notNull: true),
            ExpectedColumn("is_enabled", "INTEGER", notNull: true, defaultValue: "1"),
            ExpectedColumn("last_sync_at", "INTEGER"),
            ExpectedColumn("cursor", "TEXT"),
            ExpectedColumn("last_error", "TEXT"),
        ]),
        ("meeting_outputs", [
            ExpectedColumn("id", "TEXT", notNull: true),
            ExpectedColumn("meeting_id", "TEXT", notNull: true),
            ExpectedColumn("kind", "TEXT", notNull: true),
            ExpectedColumn("engine", "TEXT", notNull: true),
            ExpectedColumn("model_version", "TEXT", notNull: true),
            ExpectedColumn("prompt_version", "TEXT", notNull: true),
            ExpectedColumn("content_md", "TEXT", notNull: true),
            ExpectedColumn("structured_json", "TEXT"),
            ExpectedColumn("created_at", "INTEGER", notNull: true),
            ExpectedColumn("is_user_edited", "INTEGER", notNull: true, defaultValue: "0"),
        ]),
        ("app_settings", [
            ExpectedColumn("key", "TEXT", notNull: true),
            ExpectedColumn("value", "TEXT", notNull: true),
        ]),
    ]
}
