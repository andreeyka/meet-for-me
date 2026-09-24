//  GRDBSpeakerProfileRepository — реализация `SpeakerProfileRepository`,
//  C-010 (MEE-18) v7 §5.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище

import Foundation
import GRDB
import DomainCore

final class GRDBSpeakerProfileRepository: SpeakerProfileRepository {

    private let database: StorageDatabase

    init(database: StorageDatabase) {
        self.database = database
    }

    func profile(personId: UUID, modelVersion: String) async throws -> SpeakerProfile? {
        try await withDatabase(id: personId.uuidString) { db in
            try Self.row(
                db, sql: "SELECT * FROM speaker_profiles WHERE person_id = ? AND model_version = ?",
                arguments: [personId.uuidString, modelVersion]
            )
        }
    }

    func profiles(personIds: [UUID], modelVersion: String) async throws -> [SpeakerProfile] {
        guard !personIds.isEmpty else { return [] }
        return try await withDatabase(id: "?") { db in
            try personIds.compactMap {
                try Self.row(
                    db, sql: "SELECT * FROM speaker_profiles WHERE person_id = ? AND model_version = ?",
                    arguments: [$0.uuidString, modelVersion]
                )
            }
        }
    }

    func upsert(_ profile: SpeakerProfile) async throws {
        let embedding = EmbeddingCodec.encode(profile.embedding)
        do {
            try await database.dbPool.write { db in
                try db.execute(
                    sql: """
                    INSERT INTO speaker_profiles
                        (person_id, embedding, embedding_dim, model_version, sample_count, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(person_id, model_version) DO UPDATE SET
                        embedding = excluded.embedding,
                        embedding_dim = excluded.embedding_dim,
                        sample_count = excluded.sample_count,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        profile.personId.uuidString, embedding, profile.embedding.count,
                        profile.modelVersion, profile.sampleCount, EpochTime.seconds(profile.updatedAt)
                    ]
                )
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    func delete(personId: UUID) async throws {
        do {
            try await database.dbPool.write { db in
                try db.execute(
                    sql: "DELETE FROM speaker_profiles WHERE person_id = ?", arguments: [personId.uuidString]
                )
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    func deleteAll(modelVersion: String) async throws {
        do {
            try await database.dbPool.write { db in
                try db.execute(
                    sql: "DELETE FROM speaker_profiles WHERE model_version = ?", arguments: [modelVersion]
                )
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    private func withDatabase<T>(id: String, _ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        do {
            return try await database.dbPool.read(body)
        } catch {
            throw StorageErrorMapping.map(error, entity: StorageEntity.speakerProfile, id: id)
        }
    }

    private static func row(
        _ db: Database, sql: String, arguments: StatementArguments
    ) throws -> SpeakerProfile? {
        guard let row = try Row.fetchOne(db, sql: sql, arguments: arguments) else { return nil }
        let personIdText: String = row["person_id"]
        guard let personId = UUID(uuidString: personIdText) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.speakerProfile, id: personIdText, message: "person_id не разбирается в UUID"
            )
        }
        let embeddingDim: Int = row["embedding_dim"]
        let embeddingData: Data = row["embedding"]
        guard let embedding = EmbeddingCodec.decode(embeddingData, expectedDimension: embeddingDim) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.speakerProfile, id: personIdText,
                message: "длина embedding (\(embeddingData.count)) не равна embedding_dim * 4 (\(embeddingDim * 4))"
            )
        }
        return SpeakerProfile(
            personId: personId, embedding: embedding, modelVersion: row["model_version"],
            sampleCount: row["sample_count"], updatedAt: EpochTime.date(fromSeconds: row["updated_at"])
        )
    }
}
