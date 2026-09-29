//  InMemoryPersonRepository — участники и организатор встречи как люди, C-010 v27 (IR-142,
//  MEE-455), инвариант 36; задача MEE-460. Деление с основным файлом по объёму, не по смыслу.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Связь «встреча → люди» (строки `attendees` и `meetings.organizer_person_id` настоящей базы)
//  ведёт `InMemoryMeetingRepository` контейнера `InMemoryRepositories`: на каждом успешном
//  `save` он зовёт `linkMeeting(_:)`, на удалении встречи — `unlinkMeetings(_:)`. Правило
//  связи — инвариант 36 дословно, то же, что `GRDBMeetingRepositoryWrite.resolveOrCreatePersonId`:
//  (а) адрес есть и принадлежит человеку — этот человек; (б) адреса нет, а у этой же встречи
//  до сохранения был связанный человек без адреса с тем же `displayName` — тот же человек;
//  (в) иначе — новый. Одиночный репозиторий (без контейнера) связей не имеет: `attendees` — `[]`.

import Foundation
import DomainCore

extension InMemoryPersonRepository {

    // MARK: - PersonRepository (инв. 36)

    public func attendees(meetingId: UUID) async throws -> [PersonRecord] {
        log.record(port: Self.portName, method: "attendees(meetingId:)", arguments: [meetingId.uuidString])
        if let error = failureIfAny(.attendees, id: meetingId.uuidString) {
            throw error
        }
        return locked { (meetingAttendees[meetingId] ?? []).compactMap { records[$0] } }
            .sorted { lhs, rhs in
                lhs.displayName == rhs.displayName
                    ? lhs.id.uuidString < rhs.id.uuidString
                    : lhs.displayName < rhs.displayName
            }
    }

    public func organizer(meetingId: UUID) async throws -> PersonRecord? {
        log.record(port: Self.portName, method: "organizer(meetingId:)", arguments: [meetingId.uuidString])
        if let error = failureIfAny(.organizer, id: meetingId.uuidString) {
            throw error
        }
        return locked { meetingOrganizers[meetingId].flatMap { records[$0] } }
    }

    // MARK: - Связь со встречей (зовёт `InMemoryMeetingRepository`)

    /// Заменяет связи встречи по событию — как `DELETE`+`INSERT` строк `attendees` и
    /// запись `organizer_person_id` в `GRDBMeetingRepositoryWrite.saveBody`.
    func linkMeeting(_ event: MeetingEvent) {
        locked {
            var noAddress = linkedWithoutAddress(meetingId: event.id)
            let organizer = event.organizer.map { resolveOrCreate($0, noAddress: &noAddress) }
            var attendeeIds: [UUID] = []
            for attendee in event.attendees {
                let id = resolveOrCreate(attendee.person, noAddress: &noAddress)
                if !attendeeIds.contains(id) {
                    attendeeIds.append(id)
                }
            }
            meetingAttendees[event.id] = attendeeIds
            meetingOrganizers[event.id] = organizer
        }
    }

    /// Каскад удаления встречи (инв. 7): строки `attendees` уходят вместе с ней; люди остаются.
    func unlinkMeetings(_ meetingIds: Set<UUID>) {
        locked {
            for id in meetingIds {
                meetingAttendees[id] = nil
                meetingOrganizers[id] = nil
            }
        }
    }

    /// Под замком. Люди без адреса, уже связанные с встречей, — по `displayName`; при двух
    /// с одним именем — первый по `id` (тот же выбор, что у GRDB).
    private func linkedWithoutAddress(meetingId: UUID) -> [String: UUID] {
        let linked = (meetingAttendees[meetingId] ?? []) + [meetingOrganizers[meetingId]].compactMap { $0 }
        var result: [String: UUID] = [:]
        for record in linked.compactMap({ records[$0] }).sorted(by: { $0.id.uuidString < $1.id.uuidString })
        where record.emails.isEmpty && result[record.displayName] == nil {
            result[record.displayName] = record.id
        }
        return result
    }

    /// Под замком. Правило инв. 36 (а)–(в).
    private func resolveOrCreate(_ person: MeetingEvent.Person, noAddress: inout [String: UUID]) -> UUID {
        let displayName = person.name ?? person.email ?? ""
        if let email = person.email?.lowercased() {
            if let owner = emailOwner[email] {
                return owner
            }
        } else if let known = noAddress[displayName] {
            return known
        }
        let id = UUID()
        let emails = person.email.map { [$0.lowercased()] } ?? []
        records[id] = PersonRecord(id: id, displayName: displayName, emails: emails, isMe: false)
        order.append(id)
        if let email = emails.first {
            emailOwner[email] = id
        } else {
            noAddress[displayName] = id
        }
        return id
    }
}
