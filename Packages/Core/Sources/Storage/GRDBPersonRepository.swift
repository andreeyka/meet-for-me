//  GRDBPersonRepository — реализация `PersonRepository`, C-010 (MEE-18) v7 §5.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  СТРОКА: контракт не говорит, сколько строк `person_emails` затрагивает
//  `upsert(displayName:emails:)`, если переданные адреса уже принадлежат
//  РАЗНЫМ существующим людям (слияние личностей). Решение здесь — взять
//  первого совпавшего по порядку списка `emails` и присвоить ему все
//  переданные адреса, не трогая записи `persons`, на которые остальные
//  адреса ссылались раньше. Ни один критерий К1—К49/К85—К87 такой вход не
//  проверяет. За контракт не решаю.

import Foundation
import GRDB
import DomainCore

final class GRDBPersonRepository: PersonRepository {

    let database: StorageDatabase

    init(database: StorageDatabase) {
        self.database = database
    }

    func upsert(displayName: String, emails: [String]) async throws -> UUID {
        let now = EpochTime.seconds(Date())
        do {
            return try await database.dbPool.write { db in
                try Self.upsertPerson(displayName: displayName, emails: emails, now: now, db: db)
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    func person(id: UUID) async throws -> PersonRecord? {
        try await withDatabase(entity: StorageEntity.person, id: id.uuidString) { db in
            try Self.personRecord(id: id.uuidString, db: db)
        }
    }

    func person(email: String) async throws -> PersonRecord? {
        try await withDatabase(entity: StorageEntity.person, id: email) { db in
            guard let personId = try String.fetchOne(
                db, sql: "SELECT person_id FROM person_emails WHERE email = ?", arguments: [email]
            ) else { return nil }
            return try Self.personRecord(id: personId, db: db)
        }
    }

    func persons(ids: [UUID]) async throws -> [PersonRecord] {
        guard !ids.isEmpty else { return [] }
        return try await withDatabase(entity: StorageEntity.person, id: "?") { db in
            try ids.compactMap { try Self.personRecord(id: $0.uuidString, db: db) }
        }
    }

    func rename(personId: UUID, displayName: String) async throws {
        try await update(personId, entity: StorageEntity.person) { db, idText in
            try db.execute(
                sql: "UPDATE persons SET display_name = ?, updated_at = ? WHERE id = ?",
                arguments: [displayName, EpochTime.seconds(Date()), idText]
            )
        }
    }

    /// Инвариант 4 (К7): не более одной строки с `is_me = 1`.
    func setMe(personId: UUID) async throws {
        try await update(personId, entity: StorageEntity.person) { db, idText in
            try db.execute(sql: "UPDATE persons SET is_me = 0 WHERE is_me = 1")
            try db.execute(
                sql: "UPDATE persons SET is_me = 1, updated_at = ? WHERE id = ?",
                arguments: [EpochTime.seconds(Date()), idText]
            )
        }
    }

    func me() async throws -> PersonRecord? {
        try await withDatabase(entity: StorageEntity.person, id: "?") { db in
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM persons WHERE is_me = 1") else {
                return nil
            }
            return try Self.personRecord(id: id, db: db)
        }
    }

    func addNameForms(_ forms: [NameForm]) async throws {
        do {
            try await database.dbPool.write { db in
                for form in forms {
                    try db.execute(
                        sql: """
                        INSERT OR IGNORE INTO person_name_forms (person_id, form, kind)
                        VALUES (?, ?, ?)
                        """,
                        arguments: [form.personId.uuidString, form.form, form.kind.rawValue]
                    )
                }
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    func nameForms(personIds: [UUID]) async throws -> [NameForm] {
        guard !personIds.isEmpty else { return [] }
        let idTexts = personIds.map(\.uuidString)
        let sql = "SELECT person_id, form, kind FROM person_name_forms WHERE person_id IN "
            + Self.placeholders(idTexts.count)
        return try await withDatabase(entity: StorageEntity.person, id: "?") { db in
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(idTexts))
            return try rows.map { row in
                guard let personId = UUID(uuidString: row["person_id"] as String),
                      let kind = NameForm.Kind(rawValue: row["kind"] as String) else {
                    throw StorageError.dataCorrupted(
                        entity: StorageEntity.person, id: row["person_id"], message: "недопустимая форма имени"
                    )
                }
                return NameForm(personId: personId, form: row["form"], kind: kind)
            }
        }
    }

    // MARK: - Оснастка

    private func withDatabase<T>(
        entity: String, id: String, _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        do {
            return try await database.dbPool.read(body)
        } catch {
            throw StorageErrorMapping.map(error, entity: entity, id: id)
        }
    }

    private func update(
        _ personId: UUID, entity: String, _ body: @escaping @Sendable (Database, String) throws -> Void
    ) async throws {
        let idText = personId.uuidString
        do {
            let changed = try await database.dbPool.write { db -> Int in
                try body(db, idText)
                return db.changesCount
            }
            guard changed > 0 else {
                throw StorageError.notFound(entity: entity, id: idText)
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    private static func placeholders(_ count: Int) -> String {
        "(" + Array(repeating: "?", count: count).joined(separator: ", ") + ")"
    }

    private static func upsertPerson(
        displayName: String, emails: [String], now: Int64, db: Database
    ) throws -> UUID {
        for email in emails {
            if let existing = try String.fetchOne(
                db, sql: "SELECT person_id FROM person_emails WHERE email = ?", arguments: [email]
            ), let uuid = UUID(uuidString: existing) {
                try db.execute(
                    sql: "UPDATE persons SET display_name = ?, updated_at = ? WHERE id = ?",
                    arguments: [displayName, now, existing]
                )
                for newEmail in emails {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO person_emails (email, person_id) VALUES (?, ?)",
                        arguments: [newEmail, existing]
                    )
                }
                return uuid
            }
        }
        let id = UUID()
        try db.execute(
            sql: "INSERT INTO persons (id, display_name, is_me, created_at, updated_at) VALUES (?, ?, 0, ?, ?)",
            arguments: [id.uuidString, displayName, now, now]
        )
        for email in emails {
            try db.execute(
                sql: "INSERT INTO person_emails (email, person_id) VALUES (?, ?)",
                arguments: [email, id.uuidString]
            )
        }
        return id
    }

    private static func personRecord(id: String, db: Database) throws -> PersonRecord? {
        guard let row = try Row.fetchOne(db, sql: "SELECT * FROM persons WHERE id = ?", arguments: [id]) else {
            return nil
        }
        guard let personId = UUID(uuidString: id) else {
            throw StorageError.dataCorrupted(entity: StorageEntity.person, id: id, message: "id не разбирается в UUID")
        }
        let emails = try String.fetchAll(
            db, sql: "SELECT email FROM person_emails WHERE person_id = ? ORDER BY email", arguments: [id]
        )
        return PersonRecord(id: personId, displayName: row["display_name"], emails: emails, isMe: row["is_me"])
    }
}
