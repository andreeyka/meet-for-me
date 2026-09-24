//  GRDBMeetingRepository — реализация `MeetingRepository`, C-010 (MEE-18) v7 §5.
//  `meeting(sourceConnectorId:externalId:)` — C-010 v10, IR-118 (MEE-348), дописан MEE-352.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  Тело класса разбито на три файла ПО ОБЪЁМУ (`type_body_length`), не по смыслу —
//  тот же приём, каким `RepositoriesExtended.swift`/`JobQueue.swift` уже разведены
//  в `DomainCore` (см. их шапки): `GRDBMeetingRepositoryWrite.swift` несёт запись
//  (`save`, связывание персон), `GRDBMeetingRepositoryMapping.swift` — сборку
//  `MeetingRecord` из строк на чтении. Здесь — сам протокол `MeetingRepository`
//  целиком: инициализатор, чтение и удаление.
//
//  СТРОКА: контракт не говорит, как `MeetingEvent.sourceConnectorId/externalId/
//  icalUid` (собственная идентичность события) соотносится с `MeetingRecord.sources`
//  (список источников встречи) на чтении — ни один из критериев К1—К49/К85—К87 этого
//  не проверяет. Решение — в `GRDBMeetingRepositoryWrite.swift`/`…Mapping.swift`:
//  на записи эти три поля `event` гарантированно входят в набор `meeting_sources`;
//  на чтении реконструируются из строки с наибольшим `last_modified`. Решение
//  исполнителя, не владельца контракта; за контракт не решаю.

import Foundation
import GRDB
import DomainCore

final class GRDBMeetingRepository: MeetingRepository {

    let database: StorageDatabase

    init(database: StorageDatabase) {
        self.database = database
    }

    // MARK: - Чтение

    func meeting(id: UUID) async throws -> MeetingRecord? {
        try await withDatabase(entity: StorageEntity.meeting, id: id.uuidString) { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM meetings WHERE id = ?", arguments: [id.uuidString]
            ) else {
                return nil
            }
            return try Self.meetingRecord(from: row, db: db)
        }
    }

    func meeting(dedupKey: DedupKey) async throws -> MeetingRecord? {
        let dedupText = try StorageJSON.encodeToText(dedupKey)
        return try await withDatabase(entity: StorageEntity.meeting, id: "?") { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM meetings WHERE dedup_key = ?", arguments: [dedupText]
            ) else { return nil }
            return try Self.meetingRecord(from: row, db: db)
        }
    }

    /// C-010 v10, IR-118 (MEE-348), инвариант 30: пара — первичный ключ `meeting_sources`
    /// (§1) — прямая точечная выборка по нему, без перебора `meetings`.
    func meeting(sourceConnectorId: String, externalId: String) async throws -> MeetingRecord? {
        return try await withDatabase(entity: StorageEntity.meeting, id: "?") { db in
            guard let sourceRow = try Row.fetchOne(
                db,
                sql: "SELECT meeting_id FROM meeting_sources WHERE source_connector_id = ? AND external_id = ?",
                arguments: [sourceConnectorId, externalId]
            ) else {
                return nil
            }
            let meetingId: String = sourceRow["meeting_id"]
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM meetings WHERE id = ?", arguments: [meetingId]
            ) else {
                return nil
            }
            return try Self.meetingRecord(from: row, db: db)
        }
    }

    /// СТРОКА: контракт не даёт точной формулы пересечения интервала — ни один
    /// критерий К1—К49 её не проверяет. Здесь — пересечение полуоткрытых
    /// интервалов `[start_at, end_at)` с `[from, to)`.
    func meetings(from: Date, to: Date) async throws -> [MeetingRecord] {
        let fromSeconds = EpochTime.seconds(from)
        let toSeconds = EpochTime.seconds(to)
        return try await withDatabase(entity: StorageEntity.meeting, id: "?") { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM meetings WHERE start_at < ? AND end_at > ? ORDER BY start_at, id",
                arguments: [toSeconds, fromSeconds]
            )
            return try rows.map { try Self.meetingRecord(from: $0, db: db) }
        }
    }

    // MARK: - Изменение статуса и удаление

    func setStatus(_ status: MeetingStatus, meetingId: UUID) async throws {
        let idText = meetingId.uuidString
        let now = EpochTime.seconds(Date())
        do {
            let changed = try await database.dbPool.write { db -> Int in
                try db.execute(
                    sql: "UPDATE meetings SET status = ?, updated_at = ? WHERE id = ?",
                    arguments: [status.rawValue, now, idText]
                )
                return db.changesCount
            }
            guard changed > 0 else {
                throw StorageError.notFound(entity: StorageEntity.meeting, id: idText)
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    func delete(meetingIds: [UUID]) async throws {
        guard !meetingIds.isEmpty else { return }
        do {
            try await database.dbPool.write { db in
                for id in meetingIds {
                    try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id.uuidString])
                }
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    // MARK: - Оснастка чтения, общая для обоих файлов расширений

    func withDatabase<T>(
        entity: String, id: String, _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        do {
            return try await database.dbPool.read(body)
        } catch {
            throw StorageErrorMapping.map(error, entity: entity, id: id)
        }
    }
}
