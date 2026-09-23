//  GRDBMeetingRepository — реализация `MeetingRepository`, C-010 (MEE-18) v7 §5.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище
//
//  СТРОКА: контракт не говорит, как `MeetingEvent.sourceConnectorId/externalId/
//  icalUid` (собственная идентичность события) соотносится с `MeetingRecord.sources`
//  (список источников встречи) на чтении — ни один из критериев К1—К49/К85—К87 этого
//  не проверяет. Решение здесь: при записи эти три поля `event` гарантированно входят
//  в набор `meeting_sources` (добавляются, если такой пары ещё нет); при чтении
//  реконструируются из строки `meeting_sources` с наибольшим `last_modified` —
//  «последний по синхронизации источник считается текущей идентичностью события».
//  Решение исполнителя, не владельца контракта; за контракт не решаю — если
//  архитектор назовёт другое правило, это правится без изменения схемы.

import Foundation
import GRDB
import DomainCore

final class GRDBMeetingRepository: MeetingRepository {

    private let database: StorageDatabase

    init(database: StorageDatabase) {
        self.database = database
    }

    // MARK: - Запись

    func save(_ record: MeetingRecord) async throws {
        let idText = record.event.id.uuidString
        let event = record.event
        let now = EpochTime.seconds(Date())

        var sources = record.sources
        let ownKey = (event.sourceConnectorId, event.externalId)
        if !sources.contains(where: { ($0.sourceConnectorId, $0.externalId) == ownKey }) {
            sources.append(MeetingSource(
                sourceConnectorId: event.sourceConnectorId,
                externalId: event.externalId,
                icalUid: event.icalUid,
                lastModified: event.lastModified
            ))
        }

        let dedupText = try record.dedupKey.map { try StorageJSON.encodeToText($0) }

        do {
            try await database.dbPool.write { db in
                let organizerId = try event.organizer.map {
                    try Self.resolveOrCreatePersonId($0, db: db, now: now)
                }

                try db.execute(
                    sql: """
                    INSERT INTO meetings
                        (id, title, start_at, end_at, time_zone, is_all_day, is_cancelled,
                         provider, join_url, conference_meeting_id, conference_passcode,
                         organizer_person_id, location, body_text, dedup_key, status,
                         last_modified, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        title = excluded.title,
                        start_at = excluded.start_at,
                        end_at = excluded.end_at,
                        time_zone = excluded.time_zone,
                        is_all_day = excluded.is_all_day,
                        is_cancelled = excluded.is_cancelled,
                        provider = excluded.provider,
                        join_url = excluded.join_url,
                        conference_meeting_id = excluded.conference_meeting_id,
                        conference_passcode = excluded.conference_passcode,
                        organizer_person_id = excluded.organizer_person_id,
                        location = excluded.location,
                        body_text = excluded.body_text,
                        dedup_key = excluded.dedup_key,
                        status = excluded.status,
                        last_modified = excluded.last_modified,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        idText,
                        event.title,
                        EpochTime.seconds(event.start),
                        EpochTime.seconds(event.end),
                        event.timeZone,
                        event.isAllDay,
                        event.isCancelled,
                        event.conference?.provider,
                        event.conference?.joinUrl.absoluteString,
                        event.conference?.meetingId,
                        event.conference?.passcode,
                        organizerId?.uuidString,
                        event.location,
                        event.bodyText,
                        dedupText,
                        record.status.rawValue,
                        EpochTime.seconds(event.lastModified),
                        now,
                        now,
                    ]
                )

                try db.execute(sql: "DELETE FROM meeting_sources WHERE meeting_id = ?", arguments: [idText])
                for source in sources {
                    try db.execute(
                        sql: """
                        INSERT INTO meeting_sources
                            (source_connector_id, external_id, meeting_id, ical_uid, last_modified)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        arguments: [
                            source.sourceConnectorId, source.externalId, idText,
                            source.icalUid, EpochTime.seconds(source.lastModified),
                        ]
                    )
                }

                try db.execute(sql: "DELETE FROM attendees WHERE meeting_id = ?", arguments: [idText])
                for attendee in event.attendees {
                    let personId = try Self.resolveOrCreatePersonId(attendee.person, db: db, now: now)
                    try db.execute(
                        sql: """
                        INSERT INTO attendees (meeting_id, person_id, response_status, is_optional)
                        VALUES (?, ?, ?, ?)
                        """,
                        arguments: [idText, personId.uuidString, attendee.responseStatus.rawValue, attendee.isOptional]
                    )
                }
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    // MARK: - Чтение

    func meeting(id: UUID) async throws -> MeetingRecord? {
        try await withDatabase(entity: StorageEntity.meeting, id: id.uuidString) { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM meetings WHERE id = ?", arguments: [id.uuidString]) else {
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

    // MARK: - Персоны (упрощённое связывание, без публичной поверхности PersonRepository)

    private static func resolveOrCreatePersonId(
        _ person: MeetingEvent.Person, db: Database, now: Int64
    ) throws -> UUID {
        if let email = person.email,
           let existing = try String.fetchOne(
               db, sql: "SELECT person_id FROM person_emails WHERE email = ?", arguments: [email]
           ),
           let uuid = UUID(uuidString: existing) {
            return uuid
        }
        let id = UUID()
        try db.execute(
            sql: "INSERT INTO persons (id, display_name, is_me, created_at, updated_at) VALUES (?, ?, 0, ?, ?)",
            arguments: [id.uuidString, person.name ?? person.email ?? "", now, now]
        )
        if let email = person.email {
            try db.execute(
                sql: "INSERT INTO person_emails (email, person_id) VALUES (?, ?)",
                arguments: [email, id.uuidString]
            )
        }
        return id
    }

    // MARK: - Отображение строки

    private func withDatabase<T>(
        entity: String, id: String, _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T {
        do {
            return try await database.dbPool.read(body)
        } catch {
            throw StorageErrorMapping.map(error, entity: entity, id: id)
        }
    }

    private static func meetingRecord(from row: Row, db: Database) throws -> MeetingRecord {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.meeting, id: idText, message: "id встречи не разбирается в UUID"
            )
        }

        let sourceRows = try Row.fetchAll(
            db,
            sql: """
            SELECT source_connector_id, external_id, ical_uid, last_modified
            FROM meeting_sources WHERE meeting_id = ? ORDER BY last_modified DESC, source_connector_id, external_id
            """,
            arguments: [idText]
        )
        let sources: [MeetingSource] = sourceRows.map { sourceRow in
            MeetingSource(
                sourceConnectorId: sourceRow["source_connector_id"],
                externalId: sourceRow["external_id"],
                icalUid: sourceRow["ical_uid"],
                lastModified: EpochTime.date(fromSeconds: sourceRow["last_modified"])
            )
        }
        // СТРОКА (см. шапку файла): «текущая идентичность» — источник с наибольшим
        // `last_modified`; при его отсутствии (нет ни одной строки-источника) поля
        // идентичности события восстановить нечем, и они пусты дословно.
        let primary = sources.first

        let attendeeRows = try Row.fetchAll(
            db,
            sql: """
            SELECT a.response_status, a.is_optional, p.display_name, pe.email
            FROM attendees a
            JOIN persons p ON p.id = a.person_id
            LEFT JOIN person_emails pe ON pe.person_id = a.person_id
            WHERE a.meeting_id = ?
            ORDER BY p.display_name, pe.email
            """,
            arguments: [idText]
        )
        let attendees: [MeetingEvent.Attendee] = try attendeeRows.map { attendeeRow in
            let name: String = attendeeRow["display_name"]
            let email: String? = attendeeRow["email"]
            let person = try MeetingEvent.Person(name: name.isEmpty ? nil : name, email: email)
            guard let responseStatus = MeetingEvent.Attendee.ResponseStatus(
                rawValue: attendeeRow["response_status"] as String
            ) else {
                throw StorageError.dataCorrupted(
                    entity: StorageEntity.meeting, id: idText, message: "недопустимый response_status"
                )
            }
            return try MeetingEvent.Attendee(
                person: person, responseStatus: responseStatus, isOptional: attendeeRow["is_optional"]
            )
        }

        var organizer: MeetingEvent.Person?
        if let organizerId: String = row["organizer_person_id"] {
            let personRow = try Row.fetchOne(
                db,
                sql: """
                SELECT p.display_name, pe.email FROM persons p
                LEFT JOIN person_emails pe ON pe.person_id = p.id
                WHERE p.id = ?
                """,
                arguments: [organizerId]
            )
            if let personRow {
                let name: String = personRow["display_name"]
                let email: String? = personRow["email"]
                organizer = try MeetingEvent.Person(name: name.isEmpty ? nil : name, email: email)
            }
        }

        var conference: MeetingEvent.Conference?
        if let provider: String = row["provider"],
           let joinUrlText: String = row["join_url"],
           let joinUrl = URL(string: joinUrlText) {
            conference = try MeetingEvent.Conference(
                provider: provider,
                joinUrl: joinUrl,
                meetingId: row["conference_meeting_id"],
                passcode: row["conference_passcode"]
            )
        }

        let event = try MeetingEvent(
            id: id,
            sourceConnectorId: primary?.sourceConnectorId ?? "",
            externalId: primary?.externalId ?? "",
            icalUid: primary?.icalUid,
            title: row["title"],
            start: EpochTime.date(fromSeconds: row["start_at"]),
            end: EpochTime.date(fromSeconds: row["end_at"]),
            timeZone: row["time_zone"],
            isAllDay: row["is_all_day"],
            isCancelled: row["is_cancelled"],
            organizer: organizer,
            attendees: attendees,
            location: row["location"],
            bodyText: row["body_text"],
            conference: conference,
            lastModified: primary.map { $0.lastModified } ?? EpochTime.date(fromSeconds: row["last_modified"])
        )

        guard let status = MeetingStatus(rawValue: row["status"] as String) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.meeting, id: idText, message: "недопустимое значение status"
            )
        }

        let dedupKey: DedupKey?
        if let dedupText: String = row["dedup_key"] {
            dedupKey = try StorageJSON.decodeFromText(
                DedupKey.self, from: dedupText, entity: StorageEntity.meeting, id: idText
            )
        } else {
            dedupKey = nil
        }

        return MeetingRecord(event: event, dedupKey: dedupKey, status: status, sources: sources)
    }
}
