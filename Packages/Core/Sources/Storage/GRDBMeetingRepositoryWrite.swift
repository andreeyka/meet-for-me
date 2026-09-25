//  GRDBMeetingRepository — половина «запись», разведена по объёму (`type_body_length`,
//  `function_body_length`) с основным файлом и с чтением — не по смыслу.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище

import Foundation
import GRDB
import DomainCore

/// Поля одной строки `meetings` для `upsertMeetingRow`/`meetingUpsertArguments` —
/// собраны в тип, а не переданы по одному, чтобы не упереться в
/// `function_parameter_count` (лимит 5).
private struct MeetingRowInput {
    let idText: String
    let event: MeetingEvent
    let status: MeetingStatus
    let dedupText: String?
    let organizerId: UUID?
    let now: Int64
}

extension GRDBMeetingRepository {

    func save(_ record: MeetingRecord) async throws {
        do {
            try await database.dbPool.write { db in
                try Self.saveBody(record, db: db)
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    /// C-010 v20, правка v22, IR-133 (MEE-405), инвариант 33: одной транзакцией — перенос
    /// `recordings`/`meeting_outputs` проигравших на `record`, удаление `meetingIds` (тот же
    /// каскад, что `delete(meetingIds:)`, инвариант 7), и тело `save(_:)` — уникальность
    /// `dedup_key`/пары источника проверяется на шаге (3), ПОСЛЕ удаления (2): это то, что
    /// позволяет победителю унаследовать `dedup_key`/пару проигравшего без ложной коллизии
    /// с самим собой — ровно случай слияния, ради которого метод заведён.
    ///
    /// v22 (возврат РП, приёмка #134): при непустом `meetingIds` `record.event.id` ОБЯЗАН
    /// уже существовать в `meetings` — проверено явно, ДО шага (1), а не оставлено на откуп
    /// внешнему ключу `meeting_outputs.meeting_id` (`NOT NULL REFERENCES meetings(id)`,
    /// немедленный — §2 контракта, «PRAGMA foreign_keys = ON на каждом соединении»): без
    /// явной проверки отказ срабатывал только когда у кого-то из `meetingIds` были
    /// привязанные дочерние строки — без них UPDATE не менял ни одной строки, и шаг (3)
    /// молча создавал бы нового победителя. Явная проверка не отменяет внешний ключ
    /// (он остаётся страховкой), но делает отказ безусловным, как требует v22.
    func save(_ record: MeetingRecord, absorbing meetingIds: [UUID]) async throws {
        guard !meetingIds.isEmpty else {
            try await save(record)
            return
        }
        guard !meetingIds.contains(record.event.id) else {
            throw StorageError.constraintViolation(
                message: "save(_:absorbing:): meetingIds не может содержать record.event.id (инвариант 33 C-010 v22)"
            )
        }
        let winnerIdText = record.event.id.uuidString
        do {
            try await database.dbPool.write { db in
                let winnerExists = try Row.fetchOne(
                    db, sql: "SELECT 1 FROM meetings WHERE id = ?", arguments: [winnerIdText]
                ) != nil
                guard winnerExists else {
                    throw StorageError.constraintViolation(
                        message: "save(_:absorbing:): record.event.id должен существовать в meetings " +
                            "при непустом meetingIds (инвариант 33 C-010 v22)"
                    )
                }
                for id in meetingIds {
                    let idText = id.uuidString
                    try db.execute(
                        sql: "UPDATE recordings SET meeting_id = ? WHERE meeting_id = ?",
                        arguments: [winnerIdText, idText]
                    )
                    try db.execute(
                        sql: "UPDATE meeting_outputs SET meeting_id = ? WHERE meeting_id = ?",
                        arguments: [winnerIdText, idText]
                    )
                }
                try Self.deleteMeetingRows(meetingIds, db: db)
                try Self.saveBody(record, db: db)
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    static func saveBody(_ record: MeetingRecord, db: Database) throws {
        let idText = record.event.id.uuidString
        let event = record.event
        let now = EpochTime.seconds(Date())
        let sources = try sourcesIncludingOwnIdentity(of: event, declared: record.sources)
        let dedupText = try record.dedupKey.map { try StorageJSON.encodeToText($0) }
        let organizerId = try event.organizer.map {
            try resolveOrCreatePersonId($0, db: db, now: now)
        }
        let input = MeetingRowInput(
            idText: idText, event: event, status: record.status,
            dedupText: dedupText, organizerId: organizerId, now: now
        )
        try upsertMeetingRow(input, db: db)
        try replaceMeetingSources(idText: idText, sources: sources, db: db)
        try replaceAttendees(idText: idText, attendees: event.attendees, now: now, db: db)
    }

    static func deleteMeetingRows(_ ids: [UUID], db: Database) throws {
        for id in ids {
            try db.execute(sql: "DELETE FROM meetings WHERE id = ?", arguments: [id.uuidString])
        }
    }

    /// СТРОКА (шапка `GRDBMeetingRepository.swift`): собственная идентичность `event`
    /// гарантированно входит в набор источников.
    ///
    /// IR-126 (MEE-372), C-010 v18, инвариант 31 (решение РП, приёмка MEE-384): синтез
    /// снимка `MeetingEventPayload(dropping: event)` — ТОЛЬКО когда `declared` пуст (первое
    /// сохранение события без собственных источников). Непустой `declared` без identity
    /// `event` среди него БРОСАЕТ `constraintViolation`, а не молча добавляет строку со
    /// снимком и `nil`-полями идентичности: источник, заявивший о себе явно, но забывший
    /// собственную идентичность, — ошибка вызывающей стороны, не повод придумывать за неё
    /// строку с пустой парой (та же граница «строим на границе, не чиним внутри», что у
    /// `MeetingEventPayload` целиком, C-008 §«Построение значения на границе модуля»).
    static func sourcesIncludingOwnIdentity(
        of event: MeetingEvent, declared: [MeetingSource]
    ) throws -> [MeetingSource] {
        guard !declared.isEmpty else {
            return [MeetingSource(
                sourceConnectorId: event.sourceConnectorId,
                externalId: event.externalId,
                icalUid: event.icalUid,
                lastModified: event.lastModified,
                payload: MeetingEventPayload(dropping: event)
            )]
        }
        let ownKey = (event.sourceConnectorId, event.externalId)
        guard declared.contains(where: { ($0.sourceConnectorId, $0.externalId) == ownKey }) else {
            throw StorageError.constraintViolation(
                message: "meeting_sources: непустой список источников не содержит " +
                    "собственную идентичность события (инвариант 31 C-010 v18)"
            )
        }
        return declared
    }

    private static let meetingUpsertSQL = """
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
        """

    private static func meetingUpsertArguments(_ input: MeetingRowInput) -> StatementArguments {
        let event = input.event
        return [
            input.idText,
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
            input.organizerId?.uuidString,
            event.location,
            event.bodyText,
            input.dedupText,
            input.status.rawValue,
            EpochTime.seconds(event.lastModified),
            input.now,
            input.now
        ]
    }

    private static func upsertMeetingRow(_ input: MeetingRowInput, db: Database) throws {
        try db.execute(sql: meetingUpsertSQL, arguments: meetingUpsertArguments(input))
    }

    private static func replaceMeetingSources(idText: String, sources: [MeetingSource], db: Database) throws {
        try db.execute(sql: "DELETE FROM meeting_sources WHERE meeting_id = ?", arguments: [idText])
        for source in sources {
            // IR-126 (MEE-372), C-010 v18: снимок пишется дословно через DomainJSON
            // (StorageJSON.encodeToText — тот же путь, что у meetings.dedup_key), NULL при
            // отсутствии, а не пустая строка/плейсхолдер.
            let payloadText = try source.payload.map { try StorageJSON.encodeToText($0) }
            try db.execute(
                sql: """
                INSERT INTO meeting_sources
                    (source_connector_id, external_id, meeting_id, ical_uid, last_modified, raw_payload_json)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    source.sourceConnectorId, source.externalId, idText,
                    source.icalUid, EpochTime.seconds(source.lastModified), payloadText
                ]
            )
        }
    }

    private static func replaceAttendees(
        idText: String, attendees: [MeetingEvent.Attendee], now: Int64, db: Database
    ) throws {
        try db.execute(sql: "DELETE FROM attendees WHERE meeting_id = ?", arguments: [idText])
        for attendee in attendees {
            let personId = try resolveOrCreatePersonId(attendee.person, db: db, now: now)
            try db.execute(
                sql: """
                INSERT INTO attendees (meeting_id, person_id, response_status, is_optional)
                VALUES (?, ?, ?, ?)
                """,
                arguments: [idText, personId.uuidString, attendee.responseStatus.rawValue, attendee.isOptional]
            )
        }
    }

    /// Упрощённое связывание персон — без публичной поверхности `PersonRepository`
    /// (часть 2 задачи МЕЕ-324). Существующий по email человек переиспользуется,
    /// иначе заводится новая строка `persons` (без адреса, если его нет).
    static func resolveOrCreatePersonId(
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
}
