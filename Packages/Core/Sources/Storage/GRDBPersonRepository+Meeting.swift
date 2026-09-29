//  GRDBPersonRepository — участники и организатор встречи как люди, C-010 v27 (IR-142,
//  MEE-455), инвариант 36; задача MEE-460. Разведено с основным файлом по объёму
//  (`type_body_length`), не по смыслу.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  Методы ничего не добавляют и не убирают: `attendees` — ровно люди строк `attendees`
//  встречи (организатор — только если у него своя строка), `organizer` — ровно
//  `meetings.organizer_person_id`. Встречи нет — `[]`/`nil` (инв. 20); нечитаемая строка
//  человека — `dataCorrupted(entity: "Person", …)` (инв. 21) из `personRecord`.

import Foundation
import GRDB
import DomainCore

extension GRDBPersonRepository {

    func attendees(meetingId: UUID) async throws -> [PersonRecord] {
        let idText = meetingId.uuidString
        let records = try await withDatabase(entity: StorageEntity.person, id: idText) { db -> [PersonRecord] in
            let personIds = try String.fetchAll(
                db, sql: "SELECT person_id FROM attendees WHERE meeting_id = ?", arguments: [idText]
            )
            return try personIds.compactMap { try Self.personRecord(id: $0, db: db) }
        }
        return records.sorted { lhs, rhs in
            lhs.displayName == rhs.displayName
                ? lhs.id.uuidString < rhs.id.uuidString
                : lhs.displayName < rhs.displayName
        }
    }

    func organizer(meetingId: UUID) async throws -> PersonRecord? {
        let idText = meetingId.uuidString
        return try await withDatabase(entity: StorageEntity.person, id: idText) { db -> PersonRecord? in
            guard let personId = try String.fetchOne(
                db, sql: "SELECT organizer_person_id FROM meetings WHERE id = ?", arguments: [idText]
            ) else { return nil }
            return try Self.personRecord(id: personId, db: db)
        }
    }
}
