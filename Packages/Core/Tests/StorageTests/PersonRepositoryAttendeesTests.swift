//  PersonRepositoryAttendeesTests — C-010 v27 (IR-142, MEE-455), инвариант 36; задача MEE-460.
//  `PersonRepository.attendees(meetingId:)`/`organizer(meetingId:)` и правило связи участника
//  с человеком при `MeetingRepository.save(_:)`, на настоящей базе.
//
//  Модуль: storage · Владелец: DEV-2

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class PersonRepositoryAttendeesTests: StorageAsyncTestCase {

    private func person(_ name: String?, _ email: String?) throws -> MeetingEvent.Attendee {
        try MeetingEvent.Attendee(
            person: MeetingEvent.Person(name: name, email: email), responseStatus: .accepted, isOptional: false
        )
    }

    private func personCount(_ database: StorageDatabase) throws -> Int {
        try database.rawRead { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM persons") ?? -1 }
    }

    /// Инв. 36 (б): два `save` одной встречи с участником без адреса дают тот же `id`,
    /// новых людей повторный `save` не заводит.
    func test_inv36_attendeeWithoutAddressKeepsSameIdAcrossTwoSaves() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetings = temp.database.meetingRepository()
        let persons = temp.database.personRepository()
        let event = try TestFixtures.meetingEvent(
            organizer: MeetingEvent.Person(name: "Орг без адреса", email: nil),
            attendees: [try person("Гость", nil), try person("Анна", "anna@example.com")]
        )
        let record = MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: [])

        try await meetings.save(record)
        let first = try await persons.attendees(meetingId: event.id)
        let firstOrganizer = try await persons.organizer(meetingId: event.id)
        let countAfterFirst = try personCount(temp.database)
        try await meetings.save(record)
        let second = try await persons.attendees(meetingId: event.id)
        let secondOrganizer = try await persons.organizer(meetingId: event.id)

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.map(\.id), first.map(\.id), "тот же человек на повторном save")
        XCTAssertEqual(secondOrganizer?.id, firstOrganizer?.id, "организатор без адреса — тот же")
        XCTAssertEqual(try personCount(temp.database), countAfterFirst, "новых людей повторный save не завёл")
        XCTAssertEqual(first.first { $0.displayName == "Гость" }?.emails, [], "без адреса строки person_emails нет")
    }

    /// Инв. 36: порядок — `displayName` (строки Swift), при равенстве — `id`; организатор
    /// входит в `attendees` только со своей строкой; `organizer` — ровно `organizer_person_id`.
    func test_inv36_attendeesOrderedAndOrganizerOnlyWithOwnRow() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetings = temp.database.meetingRepository()
        let persons = temp.database.personRepository()
        let apart = try TestFixtures.meetingEvent(
            externalId: "ext-apart",
            organizer: MeetingEvent.Person(name: "Zed", email: "zed@example.com"),
            attendees: [try person("bob", "b@example.com"), try person("Same", "s1@example.com"),
                        try person("Same", "s2@example.com"), try person("Alice", "a@example.com")]
        )
        try await meetings.save(MeetingRecord(event: apart, dedupKey: nil, status: .scheduled, sources: []))

        let attendees = try await persons.attendees(meetingId: apart.id)
        let names = attendees.map(\.displayName)
        XCTAssertEqual(names, ["Alice", "Same", "Same", "bob"], "сравнение строк Swift без локали")
        let same = attendees.filter { $0.displayName == "Same" }.map(\.id.uuidString)
        XCTAssertEqual(same, same.sorted(), "при равном имени — по id")
        XCTAssertFalse(names.contains("Zed"), "организатор без своей строки в attendees не входит")
        let organizer = try await persons.organizer(meetingId: apart.id)
        XCTAssertEqual(organizer?.emails, ["zed@example.com"])

        let inside = try TestFixtures.meetingEvent(
            externalId: "ext-inside",
            organizer: MeetingEvent.Person(name: "Zed", email: "zed@example.com"),
            attendees: [try person("Zed", "zed@example.com")]
        )
        try await meetings.save(MeetingRecord(event: inside, dedupKey: nil, status: .scheduled, sources: []))
        let insideAttendees = try await persons.attendees(meetingId: inside.id)
        let insideOrganizer = try await persons.organizer(meetingId: inside.id)
        XCTAssertEqual(insideAttendees.map(\.id), [organizer?.id].compactMap { $0 }, "своя строка — входит, один раз")
        XCTAssertEqual(insideOrganizer?.id, organizer?.id)
    }

    /// Инв. 36 и 20: встречи нет — `[]` и `nil`, не отказ.
    func test_inv36_unknownMeetingGivesEmptyAndNil() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let persons = temp.database.personRepository()
        let attendees = try await persons.attendees(meetingId: UUID())
        let organizer = try await persons.organizer(meetingId: UUID())
        XCTAssertEqual(attendees, [])
        XCTAssertNil(organizer)
    }

    /// Граница правила (инв. 36): одно имя без адреса в одной встрече — один человек (одна
    /// строка `attendees`); то же имя в другой встрече — другой человек.
    func test_inv36_sameNameWithoutAddressOnePersonPerMeetingNotAcrossMeetings() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetings = temp.database.meetingRepository()
        let persons = temp.database.personRepository()
        let first = try TestFixtures.meetingEvent(
            externalId: "ext-a", attendees: [try person("Гость", nil), try person("Гость", nil)]
        )
        let second = try TestFixtures.meetingEvent(externalId: "ext-b", attendees: [try person("Гость", nil)])
        try await meetings.save(MeetingRecord(event: first, dedupKey: nil, status: .scheduled, sources: []))
        try await meetings.save(MeetingRecord(event: second, dedupKey: nil, status: .scheduled, sources: []))

        let firstAttendees = try await persons.attendees(meetingId: first.id)
        let secondAttendees = try await persons.attendees(meetingId: second.id)
        XCTAssertEqual(firstAttendees.count, 1, "два одноимённых без адреса — один человек, одна строка")
        XCTAssertEqual(secondAttendees.count, 1)
        XCTAssertNotEqual(firstAttendees.first?.id, secondAttendees.first?.id, "между встречами по имени не сводится")
    }

    /// Инв. 36 (в) (MEE-466): участник без имени и без адреса получает пустой `displayName`,
    /// и правило (б) применяется к пустому имени как к обычному — два анонимных участника
    /// одной встречи дают одного человека и одну строку `attendees`; повторный `save` — тот же `id`.
    func test_inv36c_anonymousAttendeesMergeIntoOnePersonStableAcrossSaves() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let meetings = temp.database.meetingRepository()
        let persons = temp.database.personRepository()
        let event = try TestFixtures.meetingEvent(
            externalId: "ext-anon", attendees: [try person(nil, nil), try person(nil, nil)]
        )
        let record = MeetingRecord(event: event, dedupKey: nil, status: .scheduled, sources: [])
        let attendeeRows = {
            try temp.database.rawRead { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM attendees WHERE meeting_id = ?",
                                 arguments: [event.id.uuidString]) ?? -1
            }
        }

        try await meetings.save(record)
        let first = try await persons.attendees(meetingId: event.id)
        let countAfterFirst = try personCount(temp.database)
        try await meetings.save(record)
        let second = try await persons.attendees(meetingId: event.id)

        XCTAssertEqual(first.count, 1, "два анонимных участника — один человек")
        XCTAssertEqual(first.first?.displayName, "", "ни имени, ни адреса — пустой displayName")
        XCTAssertEqual(first.first?.emails, [])
        XCTAssertEqual(try attendeeRows(), 1, "одна строка attendees")
        XCTAssertEqual(second.map(\.id), first.map(\.id), "повторный save — тот же id")
        XCTAssertEqual(try personCount(temp.database), countAfterFirst, "новых людей повторный save не завёл")
        XCTAssertEqual(try attendeeRows(), 1)
    }
}
