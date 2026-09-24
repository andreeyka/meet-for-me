//  GRDBMeetingOutputRepository — реализация `MeetingOutputRepository`,
//  C-010 (MEE-18) v7 §5.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  `structured_json` — байты `Data?`, которые `storage` не разбирает
//  («Что вне контракта»): связываются как BLOB напрямую (К46, вектор ii).

import Foundation
import GRDB
import DomainCore

final class GRDBMeetingOutputRepository: MeetingOutputRepository {

    private let database: StorageDatabase

    init(database: StorageDatabase) {
        self.database = database
    }

    func outputs(meetingId: UUID) async throws -> [MeetingOutput] {
        do {
            let rows = try await database.dbPool.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM meeting_outputs WHERE meeting_id = ?
                    ORDER BY kind, created_at DESC
                    """,
                    arguments: [meetingId.uuidString]
                )
            }
            return try rows.map { try Self.meetingOutput(from: $0) }
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.meetingOutput, id: meetingId.uuidString)
        }
    }

    func save(_ output: MeetingOutput) async throws {
        do {
            try await database.dbPool.write { db in
                try db.execute(sql: Self.upsertSQL, arguments: Self.arguments(output))
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    func markUserEdited(outputId: UUID, contentMarkdown: String) async throws {
        let idText = outputId.uuidString
        do {
            let changed = try await database.dbPool.write { db -> Int in
                try db.execute(
                    sql: "UPDATE meeting_outputs SET content_md = ?, is_user_edited = 1 WHERE id = ?",
                    arguments: [contentMarkdown, idText]
                )
                return db.changesCount
            }
            guard changed > 0 else {
                throw StorageError.notFound(entity: StorageEntity.meetingOutput, id: idText)
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    private static let upsertSQL = """
        INSERT INTO meeting_outputs
            (id, meeting_id, kind, engine, model_version, prompt_version,
             content_md, structured_json, created_at, is_user_edited)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            content_md = excluded.content_md,
            structured_json = excluded.structured_json,
            is_user_edited = excluded.is_user_edited
        """

    private static func arguments(_ output: MeetingOutput) -> StatementArguments {
        [
            output.id.uuidString, output.meetingId.uuidString, output.kind.rawValue,
            output.engine, output.modelVersion, output.promptVersion, output.contentMarkdown,
            output.structuredJson, EpochTime.seconds(output.createdAt), output.isUserEdited
        ]
    }

    private static func meetingOutput(from row: Row) throws -> MeetingOutput {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText), let meetingId = UUID(uuidString: row["meeting_id"] as String) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.meetingOutput, id: idText, message: "id/meeting_id не разбираются в UUID"
            )
        }
        guard let kind = MeetingOutput.Kind(rawValue: row["kind"] as String) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.meetingOutput, id: idText, message: "недопустимое значение kind"
            )
        }
        return MeetingOutput(
            id: id, meetingId: meetingId, kind: kind, engine: row["engine"],
            modelVersion: row["model_version"], promptVersion: row["prompt_version"],
            contentMarkdown: row["content_md"], structuredJson: row["structured_json"],
            createdAt: EpochTime.date(fromSeconds: row["created_at"]), isUserEdited: row["is_user_edited"]
        )
    }
}
