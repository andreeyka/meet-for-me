//  GRDBMeetingRepository — половина «чтение»: сборка `MeetingRecord` из строк.
//  Разведена по объёму (`type_body_length`, `function_body_length`) с основным
//  файлом и с записью — не по смыслу.
//
//  Модуль: storage · Владелец: DEV-2 · Слой: хранилище

import Foundation
import GRDB
import DomainCore

extension GRDBMeetingRepository {

    static func meetingRecord(from row: Row, db: Database) throws -> MeetingRecord {
        let idText: String = row["id"]
        guard let id = UUID(uuidString: idText) else {
            throw StorageError.dataCorrupted(
                entity: StorageEntity.meeting, id: idText, message: "id встречи не разбирается в UUID"
            )
        }

        let sources = try loadSources(meetingId: idText, db: db)
        // СТРОКА (шапка `GRDBMeetingRepository.swift`): «текущая идентичность» —
        // источник с наибольшим `last_modified`; при его отсутствии поля
        // идентичности события восстановить нечем, и они пусты дословно.
        let primary = sources.first
        let attendees = try loadAttendees(meetingId: idText, db: db)
        let organizer = try loadOrganizer(row: row, db: db)
        let conference = try loadConference(row: row)

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
        let dedupKey = try loadDedupKey(row: row, idText: idText)

        return MeetingRecord(event: event, dedupKey: dedupKey, status: status, sources: sources)
    }

    private static func loadSources(meetingId: String, db: Database) throws -> [MeetingSource] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT source_connector_id, external_id, ical_uid, last_modified, raw_payload_json
            FROM meeting_sources WHERE meeting_id = ? ORDER BY last_modified DESC, source_connector_id, external_id
            """,
            arguments: [meetingId]
        )
        // IR-126 (MEE-372), C-010 v18: raw_payload_json NULL ⇔ payload nil; непустая
        // колонка читается через DomainJSON (StorageJSON.decodeFromText), тем же путём,
        // что meetings.dedup_key.
        return try rows.map { row in
            let payloadText: String? = row["raw_payload_json"]
            let payload = try payloadText.map {
                try StorageJSON.decodeFromText(
                    MeetingEventPayload.self, from: $0, entity: StorageEntity.meeting, id: meetingId
                )
            }
            return MeetingSource(
                sourceConnectorId: row["source_connector_id"],
                externalId: row["external_id"],
                icalUid: row["ical_uid"],
                lastModified: EpochTime.date(fromSeconds: row["last_modified"]),
                payload: payload
            )
        }
    }

    private static func loadAttendees(meetingId: String, db: Database) throws -> [MeetingEvent.Attendee] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT a.response_status, a.is_optional, p.display_name, pe.email
            FROM attendees a
            JOIN persons p ON p.id = a.person_id
            LEFT JOIN person_emails pe ON pe.person_id = a.person_id
            WHERE a.meeting_id = ?
            ORDER BY p.display_name, pe.email
            """,
            arguments: [meetingId]
        )
        return try rows.map { row in
            let name: String = row["display_name"]
            let email: String? = row["email"]
            let person = try MeetingEvent.Person(name: name.isEmpty ? nil : name, email: email)
            guard let responseStatus = MeetingEvent.Attendee.ResponseStatus(
                rawValue: row["response_status"] as String
            ) else {
                throw StorageError.dataCorrupted(
                    entity: StorageEntity.meeting, id: meetingId, message: "недопустимый response_status"
                )
            }
            return try MeetingEvent.Attendee(
                person: person, responseStatus: responseStatus, isOptional: row["is_optional"]
            )
        }
    }

    private static func loadOrganizer(row: Row, db: Database) throws -> MeetingEvent.Person? {
        guard let organizerId: String = row["organizer_person_id"] else { return nil }
        guard let personRow = try Row.fetchOne(
            db,
            sql: """
            SELECT p.display_name, pe.email FROM persons p
            LEFT JOIN person_emails pe ON pe.person_id = p.id
            WHERE p.id = ?
            """,
            arguments: [organizerId]
        ) else { return nil }
        let name: String = personRow["display_name"]
        let email: String? = personRow["email"]
        return try MeetingEvent.Person(name: name.isEmpty ? nil : name, email: email)
    }

    private static func loadConference(row: Row) throws -> MeetingEvent.Conference? {
        guard let provider: String = row["provider"],
              let joinUrlText: String = row["join_url"],
              let joinUrl = URL(string: joinUrlText) else { return nil }
        return try MeetingEvent.Conference(
            provider: provider,
            joinUrl: joinUrl,
            meetingId: row["conference_meeting_id"],
            passcode: row["conference_passcode"]
        )
    }

    private static func loadDedupKey(row: Row, idText: String) throws -> DedupKey? {
        guard let dedupText: String = row["dedup_key"] else { return nil }
        return try StorageJSON.decodeFromText(
            DedupKey.self, from: dedupText, entity: StorageEntity.meeting, id: idText
        )
    }
}
