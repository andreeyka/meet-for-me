//  GRDBConnectorRepository — реализация `ConnectorRepository`, C-010 (MEE-18) v7 §5.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  `settings_json` — байты `Data`, которые `storage` не разбирает («Что вне
//  контракта»): связываются как BLOB напрямую, не через `DomainJSON`, и
//  доезжают наружу побайтно независимо от того, что внутри (К46, вектор i).
//  `selected_calendar_ids_json` — одна из четырёх колонок инварианта 27,
//  разбирается `DomainJSON` в `[String]`.

import Foundation
import GRDB
import DomainCore

final class GRDBConnectorRepository: ConnectorRepository {

    private let database: StorageDatabase

    init(database: StorageDatabase) {
        self.database = database
    }

    func all() async throws -> [ConnectorRecord] {
        do {
            let rows = try await database.dbPool.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM connectors ORDER BY id")
            }
            return try rows.map { try Self.connectorRecord(from: $0) }
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.connector, id: "?")
        }
    }

    func upsert(_ record: ConnectorRecord) async throws {
        let idsJSON = try StorageJSON.encodeToText(record.selectedCalendarIds)
        do {
            try await database.dbPool.write { db in
                try db.execute(sql: Self.upsertSQL, arguments: Self.arguments(record, idsJSON: idsJSON))
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    func setCursor(_ cursor: String?, connectorId: String) async throws {
        try await update(connectorId) { db, id in
            try db.execute(sql: "UPDATE connectors SET cursor = ? WHERE id = ?", arguments: [cursor, id])
        }
    }

    func setSyncOutcome(at: Date, error: String?, connectorId: String) async throws {
        try await update(connectorId) { db, id in
            try db.execute(
                sql: "UPDATE connectors SET last_sync_at = ?, last_error = ? WHERE id = ?",
                arguments: [EpochTime.seconds(at), error, id]
            )
        }
    }

    func delete(connectorId: String) async throws {
        do {
            try await database.dbPool.write { db in
                try db.execute(sql: "DELETE FROM connectors WHERE id = ?", arguments: [connectorId])
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    // MARK: - Оснастка

    private func update(
        _ connectorId: String, _ body: @escaping @Sendable (Database, String) throws -> Void
    ) async throws {
        do {
            let changed = try await database.dbPool.write { db -> Int in
                try body(db, connectorId)
                return db.changesCount
            }
            guard changed > 0 else {
                throw StorageError.notFound(entity: StorageEntity.connector, id: connectorId)
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    private static let upsertSQL = """
        INSERT INTO connectors
            (id, type, plugin_id, settings_json, keychain_namespace, selected_calendar_ids_json,
             is_enabled, last_sync_at, cursor, last_error)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            type = excluded.type,
            plugin_id = excluded.plugin_id,
            settings_json = excluded.settings_json,
            keychain_namespace = excluded.keychain_namespace,
            selected_calendar_ids_json = excluded.selected_calendar_ids_json,
            is_enabled = excluded.is_enabled,
            last_sync_at = excluded.last_sync_at,
            cursor = excluded.cursor,
            last_error = excluded.last_error
        """

    private static func arguments(_ record: ConnectorRecord, idsJSON: String) -> StatementArguments {
        [
            record.id, record.type, record.pluginId, record.settingsJson,
            record.keychainNamespace, idsJSON, record.isEnabled,
            record.lastSyncAt.map(EpochTime.seconds), record.cursor, record.lastError
        ]
    }

    private static func connectorRecord(from row: Row) throws -> ConnectorRecord {
        let id: String = row["id"]
        let idsText: String = row["selected_calendar_ids_json"]
        let ids: [String] = try StorageJSON.decodeFromText(
            [String].self, from: idsText, entity: StorageEntity.connector, id: id
        )
        return ConnectorRecord(
            id: id, type: row["type"], pluginId: row["plugin_id"], settingsJson: row["settings_json"],
            keychainNamespace: row["keychain_namespace"], selectedCalendarIds: ids,
            isEnabled: row["is_enabled"],
            lastSyncAt: (row["last_sync_at"] as Int64?).map(EpochTime.date(fromSeconds:)),
            cursor: row["cursor"], lastError: row["last_error"]
        )
    }
}
