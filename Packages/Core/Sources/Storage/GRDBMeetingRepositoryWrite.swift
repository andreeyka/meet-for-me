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
        let idText = record.event.id.uuidString
        let event = record.event
        let now = EpochTime.seconds(Date())
        let sources = Self.sourcesIncludingOwnIdentity(of: event, declared: record.sources)
        let dedupText = try record.dedupKey.map { try StorageJSON.encodeToText($0) }

        do {
            try await database.dbPool.write { db in
                let organizerId = try event.organizer.map {
                    try Self.resolveOrCreatePersonId($0, db: db, now: now)
                }
                let input = MeetingRowInput(
                    idText: idText, event: event, status: record.status,
                    dedupText: dedupText, organizerId: organizerId, now: now
                )
                try Self.upsertMeetingRow(input, db: db)
                try Self.replaceMeetingSources(idText: idText, sources: sources, db: db)
                try Self.replaceAttendees(idText: idText, attendees: event.attendees, now: now, db: db)
            }
        } catch {
            throw StorageErrorMapping.mapWrite(error)
        }
    }

    /// СТРОКА (шапка `GRDBMeetingRepository.swift`): собственная идентичность
    /// `event` гарантированно входит в набор источников, добавляется, если такой
    /// пары ещё нет.
    static func sourcesIncludingOwnIdentity(
        of event: MeetingEvent, declared: [MeetingSource]
    ) -> [MeetingSource] {
        let ownKey = (event.sourceConnectorId, event.externalId)
        var sources = declared
        if !sources.contains(where: { ($0.sourceConnectorId, $0.externalId) == ownKey }) {
            sources.append(MeetingSource(
                sourceConnectorId: event.sourceConnectorId,
                externalId: event.externalId,
                icalUid: event.icalUid,
                lastModified: event.lastModified
            ))
        }
        return sources
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
            try db.execute(
                sql: """
                INSERT INTO meeting_sources
                    (source_connector_id, external_id, meeting_id, ical_uid, last_modified)
                VALUES (?, ?, ?, ?, ?)
                """,
                arguments: [
                    source.sourceConnectorId, source.externalId, idText,
                    source.icalUid, EpochTime.seconds(source.lastModified)
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
