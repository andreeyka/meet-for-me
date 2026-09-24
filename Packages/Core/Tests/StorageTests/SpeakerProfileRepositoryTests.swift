//  SpeakerProfileRepositoryTests — К15 перечня MEE-189 (группа B), владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class SpeakerProfileRepositoryTests: StorageAsyncTestCase {

    func testK15_embeddingLengthMustMatchEmbeddingDimTimesFour() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let repository = temp.database.speakerProfileRepository()
        let personId = try await temp.database.personRepository().upsert(displayName: "A", emails: [])

        // (i) upsert с embedding из 192 значений — в колонке ровно 768 байт,
        // profile(...) возвращает те же 192 значения поэлементно.
        let values = (0..<192).map { Float($0) / 10 }
        try await repository.upsert(SpeakerProfile(
            personId: personId, embedding: values, modelVersion: "v1", sampleCount: 5, updatedAt: TestFixtures.epoch
        ))
        let storedLength = try temp.database.rawRead { db in
            try Row.fetchOne(
                db, sql: "SELECT length(embedding) AS len FROM speaker_profiles WHERE person_id = ?",
                arguments: [personId.uuidString]
            )?["len"] as Int?
        }
        XCTAssertEqual(storedLength, 768)
        let read = try await repository.profile(personId: personId, modelVersion: "v1")
        XCTAssertEqual(read?.embedding, values)

        // (ii) строка через Ш7 с embedding_dim=192 и embedding длиной 512 байт
        // (не кратно ожидаемым 768) — чтение даёт dataCorrupted.
        let otherPerson = try await temp.database.personRepository().upsert(displayName: "B", emails: [])
        try temp.database.rawWrite { db in
            try db.execute(
                sql: """
                INSERT INTO speaker_profiles
                    (person_id, embedding, embedding_dim, model_version, sample_count, updated_at)
                VALUES (?, ?, 192, 'v1', 1, 0)
                """,
                arguments: [otherPerson.uuidString, Data(repeating: 0, count: 512)]
            )
        }
        do {
            _ = try await repository.profile(personId: otherPerson, modelVersion: "v1")
            XCTFail("рассогласованная длина embedding обязана дать dataCorrupted")
        } catch let error as StorageError {
            guard case .dataCorrupted = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)")
                return
            }
        }

        // (iii) embedding_dim=0 и пустой embedding — читается без ошибки.
        let thirdPerson = try await temp.database.personRepository().upsert(displayName: "C", emails: [])
        try await repository.upsert(SpeakerProfile(
            personId: thirdPerson, embedding: [], modelVersion: "v1", sampleCount: 0, updatedAt: TestFixtures.epoch
        ))
        let empty = try await repository.profile(personId: thirdPerson, modelVersion: "v1")
        XCTAssertEqual(empty?.embedding, [])
    }
}
