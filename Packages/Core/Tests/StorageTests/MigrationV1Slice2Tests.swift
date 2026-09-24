//  MigrationV1Slice2Tests — миграция `v1-slice2` (IR-126, MEE-372, C-010 v18), MEE-384.
//
//  Владелец: DEV-2. Строит базу на ТОЛЬКО `v1-slice1` напрямую (не через
//  `StorageDatabase`, чей инициализатор сразу гоняет ПОЛНЫЙ мигратор, — здесь нужно
//  промежуточное состояние ДО `v1-slice2`, которого через штатный вход не получить),
//  сеет строку так, как её мог оставить `v1-slice1`, затем догоняет полным мигратором
//  `StorageMigrations.migrator` — GRDB применяет только НЕДОСТАЮЩУЮ `v1-slice2`,
//  `v1-slice1` уже отмечена применённой по идентификатору.

import XCTest
import GRDB
@testable import Storage

final class MigrationV1Slice2Tests: XCTestCase {

    /// На базе с данными `v1-slice1` после миграции: `connectors.cursor` обнулён у всех
    /// строк, старые строки `meetings`/`meeting_sources` целы, `raw_payload_json IS NULL`
    /// у существовавшей до миграции строки.
    func test_migration_v1slice2_backfillsNullPayloadAndClearsConnectorCursor() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-v1slice2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dbQueue = try DatabaseQueue(path: directory.appendingPathComponent("db.sqlite").path)

        var onlyV1Slice1 = DatabaseMigrator()
        onlyV1Slice1.registerMigration("v1-slice1") { db in
            try db.execute(sql: StorageMigrations.schemaSQL)
        }
        try onlyV1Slice1.migrate(dbQueue)

        let (meetingId, connectorId) = try Self.seedV1Slice1Rows(dbQueue)

        // Полный мигратор: v1-slice1 уже применена, применяется только v1-slice2.
        try StorageMigrations.migrator.migrate(dbQueue)

        try Self.assertBackfilled(dbQueue, meetingId: meetingId, connectorId: connectorId)
    }

    /// Строки так, как их мог оставить `v1-slice1`: встреча с одним источником (ещё без
    /// `raw_payload_json` — колонки тогда не было) и коннектор с непустым `cursor`.
    private static func seedV1Slice1Rows(_ dbQueue: DatabaseQueue) throws -> (meetingId: String, connectorId: String) {
        let meetingId = UUID().uuidString
        let connectorId = UUID().uuidString
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO meetings
                    (id, title, start_at, end_at, time_zone, is_all_day, is_cancelled,
                     status, last_modified, created_at, updated_at)
                VALUES (?, 'до миграции', 0, 1800, 'UTC', 0, 0, 'scheduled', 0, 0, 0)
                """,
                arguments: [meetingId]
            )
            try db.execute(
                sql: """
                INSERT INTO meeting_sources (source_connector_id, external_id, meeting_id, ical_uid, last_modified)
                VALUES ('eventkit', 'ext-v1slice1', ?, NULL, 0)
                """,
                arguments: [meetingId]
            )
            try db.execute(
                sql: """
                INSERT INTO connectors
                    (id, type, settings_json, keychain_namespace, selected_calendar_ids_json, cursor)
                VALUES (?, 'eventkit', '{}', 'ns', '[]', 'старый-курсор')
                """,
                arguments: [connectorId]
            )
        }
        return (meetingId, connectorId)
    }

    private static func assertBackfilled(_ dbQueue: DatabaseQueue, meetingId: String, connectorId: String) throws {
        try dbQueue.read { db in
            let cursor = try String.fetchOne(
                db, sql: "SELECT cursor FROM connectors WHERE id = ?", arguments: [connectorId]
            )
            XCTAssertNil(cursor, "v1-slice2 обнуляет cursor у уже существующих connectors")

            let title = try String.fetchOne(db, sql: "SELECT title FROM meetings WHERE id = ?", arguments: [meetingId])
            XCTAssertEqual(title, "до миграции", "старая строка meetings цела")

            let sourceRow = try Row.fetchOne(
                db, sql: "SELECT external_id, raw_payload_json FROM meeting_sources WHERE meeting_id = ?",
                arguments: [meetingId]
            )
            let payloadValue: String? = sourceRow?["raw_payload_json"]
            XCTAssertNil(payloadValue, "старая строка meeting_sources — raw_payload_json NULL")
            let externalId: String? = sourceRow?["external_id"]
            XCTAssertEqual(externalId, "ext-v1slice1", "старая строка meeting_sources цела")
        }
    }
}
