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
}
