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

        try Self.assertSecondIsMeRowRejectedWithConstraintText(temp.database)
    }

    // (ii) прямая вставка второй строки is_me=1 через Ш7 — отвергнута
    // частичным уникальным индексом `idx_persons_me`.
    //
    // СТРОКА: ни один метод PersonRepository не может физически столкнуться
    // с этим нарушением — тело `GRDBPersonRepository.setMe(personId:)`
    // (файл в этом же модуле) сперва снимает `is_me` со ВСЕХ строк и только
    // следующим оператором ставит его целевой, обе строки — в ОДНОЙ
    // транзакции `database.dbPool.write` (GRDB оборачивает `write(_:)` в
    // транзакцию целиком, не допуская чужой записи между двумя операторами
    // одного вызова, и один писатель SQLite не даёт двум таким транзакциям
    // перемежаться даже при параллельных вызовах); `upsert`/`upsertPerson`
    // пишут `is_me` только константой `0`. Решение РП по этому доводу: Ш7
    // (`rawWrite` — прямой алиас `dbPool.write`, не отдельный путь) допустим
    // как единственный наблюдаемый путь к нарушению.
    private static func assertSecondIsMeRowRejectedWithConstraintText(_ database: StorageDatabase) throws {
        do {
            try database.rawWrite { db in
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
            // Явный литерал, написанный в тесте, а не собранный тем же кодом,
            // который проверяется (по возврату РП — прежняя версия сравнивала
            // реализацию саму с собой и осталась бы зелёной при любом тексте):
            // SQLite называет нарушенное ограничение по имени колонки, а не
            // индекса, — "UNIQUE constraint failed: persons.is_me".
            XCTAssertTrue(
                message.contains("persons.is_me"),
                "текст несёт явный литерал колонки ограничения: \(message)"
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
