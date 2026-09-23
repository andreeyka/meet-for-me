//  GRDBRecordingRepository — реализация `RecordingRepository`, C-010 (MEE-18) v8 §5.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  IR-113 (МЕЕ-326) закрыт изданием C-010 v8, инвариант 7: `save(_:)` пишет
//  `recordings.meeting_id` из `manifest.meetingId` только при вставке НОВОЙ
//  строки; у уже существующей строки колонку не трогает ни в какую сторону —
//  `meeting_id` в `ON CONFLICT … DO UPDATE SET` ниже отсутствует нарочно.

import Foundation
import GRDB
import DomainCore

final class GRDBRecordingRepository: RecordingRepository {

    private let database: StorageDatabase
    private let fileLayout: FileLayout

    init(database: StorageDatabase, fileLayout: FileLayout) {
        self.database = database
        self.fileLayout = fileLayout
    }

    // MARK: - Запись

    func save(_ record: RecordingRecord) async throws {
        let manifestText = try StorageJSON.encodeToText(record.manifest)
        let idText = record.manifest.recordingId.uuidString
        let now = EpochTime.seconds(Date())
        do {
            try await database.dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO recordings
                        (id, meeting_id, directory_name, started_at, ended_at,
                         manifest_json, is_finalized, status, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        directory_name = excluded.directory_name,
                        started_at = excluded.started_at,
                        ended_at = excluded.ended_at,
                        manifest_json = excluded.manifest_json,
                        is_finalized = excluded.is_finalized,
                        status = excluded.status,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        idText,
                        record.manifest.meetingId?.uuidString,
                        record.manifest.directoryName,
                        EpochTime.seconds(record.manifest.startedAt),
                        record.manifest.endedAt.map(EpochTime.seconds),
                        manifestText,
                        record.manifest.isFinalized ? 1 : 0,
                        record.status.rawValue,
                        now,
                        now
                    ]
                )
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    // MARK: - Чтение

    func recording(id: UUID) async throws -> RecordingRecord? {
        do {
            return try await database.dbPool.read { db in
                guard let row = try Row.fetchOne(
                    db, sql: "SELECT * FROM recordings WHERE id = ?", arguments: [id.uuidString]
                ) else { return nil }
                return try Self.recordingRecord(from: row)
            }
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.recording, id: id.uuidString)
        }
    }

    func recordings(meetingId: UUID) async throws -> [RecordingRecord] {
        try await fetchRecordings(
            sql: "SELECT * FROM recordings WHERE meeting_id = ? ORDER BY created_at, id",
            arguments: [meetingId.uuidString]
        )
    }

    /// Инвариант 28: `status != .finalized` — `.recording`, `.stopping`, `.failed`.
    func unfinalized() async throws -> [RecordingRecord] {
        try await fetchRecordings(
            sql: "SELECT * FROM recordings WHERE status <> ? ORDER BY created_at, id",
            arguments: [RecordingStatus.finalized.rawValue]
        )
    }

    /// Инвариант 29: `recordings.meeting_id IS NULL` — по колонке, не по `manifest.meetingId`.
    func adHoc() async throws -> [RecordingRecord] {
        try await fetchRecordings(
            sql: "SELECT * FROM recordings WHERE meeting_id IS NULL ORDER BY created_at, id"
        )
    }

    // MARK: - Удаление

    func delete(recordingId: UUID, deleteFiles: Bool) async throws {
        let idText = recordingId.uuidString
        let directoryName: String?
        do {
            directoryName = try await database.dbPool.write { db -> String? in
                guard let existing = try String.fetchOne(
                    db, sql: "SELECT directory_name FROM recordings WHERE id = ?", arguments: [idText]
                ) else { return nil }
                try db.execute(sql: "DELETE FROM recordings WHERE id = ?", arguments: [idText])
                return existing
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }

        guard deleteFiles, let directoryName else { return }
        let directoryURL = fileLayout.recordingDirectory(directoryName)
        do {
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                try FileManager.default.removeItem(at: directoryURL)
            }
        } catch {
            throw StorageError.io(message: String(describing: error))
        }
    }

    // MARK: - Отображение строки

    private func fetchRecordings(sql: String, arguments: StatementArguments = []) async throws -> [RecordingRecord] {
        do {
            let rows = try await database.dbPool.read { db in
                try Row.fetchAll(db, sql: sql, arguments: arguments)
            }
            return try rows.map { try Self.recordingRecord(from: $0) }
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.recording, id: "?")
        }
    }

    private static func recordingRecord(from row: Row) throws -> RecordingRecord {
        let idText: String = row["id"]
        let manifestText: String = row["manifest_json"]
        let statusText: String = row["status"]
        let manifest: RecordingManifest = try StorageJSON.decodeFromText(
            RecordingManifest.self, from: manifestText, entity: StorageEntity.recording, id: idText
        )
        guard let status = RecordingStatus(rawValue: statusText) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.recording, id: idText,
                message: "недопустимое значение status: \(statusText)"
            )
        }
        return RecordingRecord(manifest: manifest, status: status)
    }
}
