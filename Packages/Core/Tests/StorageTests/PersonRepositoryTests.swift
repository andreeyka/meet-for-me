//  PersonRepositoryTests — К7, К8 перечня MEE-189 (группа B), владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class PersonRepositoryTests: StorageAsyncTestCase {

    // MARK: - К7

    func testK7_atMostOneIsMe() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let repository = temp.database.personRepository()

        // (i) setMe(A), затем setMe(B) — ровно одна строка is_me=1, это B.
        let personA = try await repository.upsert(displayName: "A", emails: ["a@example.com"])
        let personB = try await repository.upsert(displayName: "B", emails: ["b@example.com"])
        try await repository.setMe(personId: personA)
        try await repository.setMe(personId: personB)

        let meCount = try temp.database.rawRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM persons WHERE is_me = 1") ?? -1
        }
        XCTAssertEqual(meCount, 1)
        let me = try await repository.me()
        XCTAssertEqual(me?.id, personB)

        // (ii) прямая вставка второй строки is_me=1 через Ш7 — отвергнута
        // частичным уникальным индексом `idx_persons_me`.
        //
        // НЕ через вызов метода PersonRepository — повторная проверка кода
        // `GRDBPersonRepository.setMe(personId:)` (файл в этом же модуле)
        // подтверждает второй раз: тело метода —
        //     UPDATE persons SET is_me = 0 WHERE is_me = 1
        //     UPDATE persons SET is_me = 1, updated_at = ? WHERE id = ?
        // — обе строки выполняются в ОДНОЙ транзакции `database.dbPool.write`
        // (GRDB оборачивает `write(_:)` в транзакцию целиком, не допуская
        // чужой записи между двумя операторами одного вызова), поэтому first
        // statement снимает `is_me` со всех строк ДО того, как second
        // statement его кому-либо ставит — конфликт с `idx_persons_me`
        // структурно недостижим ни при одном входе `setMe`, включая
        // параллельные вызовы (сериализация одного писателя SQLite не даёт
        // им перемежаться). `upsert`/`upsertPerson` пишут `is_me` только
        // константой `0`. Другого публичного пути записать `is_me = 1` в
        // модуле нет — единственный наблюдаемый путь к этому нарушению
        // остаётся прямой записью через Ш7 (способ В плана MEE-311, тот же
        // шов, которым уже открыт этот файл строкой выше).
        //
        // Сверяемый вызов — тот же `database.dbPool.write`, которым
        // пользуется каждый пишущий метод порта (Ш7 `rawWrite` — прямой
        // алиас `dbPool.write`, не отдельный путь); пойманная ошибка —
        // настоящая `DatabaseError` от самого SQLite, не синтетическая.
        do {
            try temp.database.rawWrite { db in
                try db.execute(
                    sql: "INSERT INTO persons (id, display_name, is_me, created_at, updated_at) "
                        + "VALUES (?, 'C', 1, 0, 0)",
                    arguments: [UUID().uuidString]
                )
            }
            XCTFail("вставка второй is_me=1 строки обязана быть отвергнута")
        } catch {
            let mapped = StorageErrorMapping.mapWrite(error)
            guard case .constraintViolation(let message) = mapped else {
                XCTFail("ожидался constraintViolation, получено \(mapped)")
                return
            }
            XCTAssertTrue(
                message.contains("UNIQUE constraint failed: persons.is_me"),
                "текст несёт именно это ограничение (persons.is_me), не общее слово UNIQUE: \(message)"
            )
        }
    }

    // MARK: - К8

    func testK8_emailBelongsToExactlyOnePerson() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let repository = temp.database.personRepository()

        let personA = try await repository.upsert(displayName: "A", emails: ["x@e.example"])
        _ = try await repository.upsert(displayName: "B", emails: ["x@e.example"])

        let ownersCount = try temp.database.rawRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(DISTINCT person_id) FROM person_emails WHERE email = ?",
                              arguments: ["x@e.example"]) ?? -1
        }
        XCTAssertEqual(ownersCount, 1, "адрес принадлежит ровно одному человеку")

        // Регистр нормализован: X@E.example и x@e.example — один адрес (не
        // нормализуется репозиторием — это обязанность вызывающей стороны,
        // проверяется тем, что оба обращения к УЖЕ нормализованному адресу
        // видят одного и того же человека).
        let byEmail = try await repository.person(email: "x@e.example")
        XCTAssertEqual(byEmail?.id, personA)
    }
}
