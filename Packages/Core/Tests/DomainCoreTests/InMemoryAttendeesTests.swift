//  InMemoryAttendeesTests — фейки `InMemoryRepositories` держат инвариант 36 C-010 v27 (IR-142,
//  MEE-455) тем же правилом, что `storage`; задача MEE-460.

import XCTest
import DomainCore
import DomainTestKit

final class InMemoryAttendeesTests: XCTestCase {

    private func attendee(_ name: String?, _ email: String?) throws -> MeetingEvent.Attendee {
        try MeetingEvent.Attendee(
            person: MeetingEvent.Person(name: name, email: email), responseStatus: .accepted, isOptional: false
        )
    }

    private func event(
        id: UUID = UUID(), externalId: String, organizer: MeetingEvent.Person?, attendees: [MeetingEvent.Attendee]
    ) throws -> MeetingEvent {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return try MeetingEvent(
            id: id, sourceConnectorId: "eventkit", externalId: externalId, icalUid: nil, title: "Встреча",
            start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
            isCancelled: false, organizer: organizer, attendees: attendees, location: nil, bodyText: nil,
            conference: nil, lastModified: start
        )
    }

    func test_inv36_attendeeWithoutAddressKeepsSameIdAcrossTwoSaves() async throws {
        let repositories = InMemoryRepositories()
        let meeting = try event(
            externalId: "e1", organizer: MeetingEvent.Person(name: "Орг", email: nil),
            attendees: [try attendee("Гость", nil), try attendee("Анна", "anna@example.com")]
        )
        let record = MeetingRecord(event: meeting, dedupKey: nil, status: .scheduled, sources: [])
        try await repositories.meetings.save(record)
        let first = try await repositories.persons.attendees(meetingId: meeting.id)
        let firstOrganizer = try await repositories.persons.organizer(meetingId: meeting.id)
        let countAfterFirst = repositories.persons.storedRecords.count
        try await repositories.meetings.save(record)
        let second = try await repositories.persons.attendees(meetingId: meeting.id)
        let secondOrganizer = try await repositories.persons.organizer(meetingId: meeting.id)

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(second.map(\.id), first.map(\.id))
        XCTAssertEqual(secondOrganizer?.id, firstOrganizer?.id)
        XCTAssertNotNil(firstOrganizer)
        XCTAssertEqual(repositories.persons.storedRecords.count, countAfterFirst)
    }

    func test_inv36_orderOrganizerAndUnknownMeeting() async throws {
        let repositories = InMemoryRepositories()
        let meeting = try event(
            externalId: "e2", organizer: MeetingEvent.Person(name: "Zed", email: "zed@example.com"),
            attendees: [try attendee("bob", "b@example.com"), try attendee("Alice", "a@example.com")]
        )
        try await repositories.meetings.save(
            MeetingRecord(event: meeting, dedupKey: nil, status: .scheduled, sources: [])
        )
        let names = try await repositories.persons.attendees(meetingId: meeting.id).map(\.displayName)
        XCTAssertEqual(names, ["Alice", "bob"], "организатор без своей строки не входит")
        let organizer = try await repositories.persons.organizer(meetingId: meeting.id)
        XCTAssertEqual(organizer?.displayName, "Zed")

        let none = try await repositories.persons.attendees(meetingId: UUID())
        let noOrganizer = try await repositories.persons.organizer(meetingId: UUID())
        XCTAssertEqual(none, [])
        XCTAssertNil(noOrganizer)

        try await repositories.meetings.delete(meetingIds: [meeting.id])
        let afterDelete = try await repositories.persons.attendees(meetingId: meeting.id)
        let organizerAfterDelete = try await repositories.persons.organizer(meetingId: meeting.id)
        XCTAssertEqual(afterDelete, [], "каскад удаления встречи")
        XCTAssertNil(organizerAfterDelete)
    }

    /// Инв. 36 (в) (MEE-466): участник без имени и без адреса — пустой `displayName`, правило (б)
    /// к пустому имени как к обычному: два анонимных участника одной встречи — один человек и
    /// одна строка участия; повторный `save` сохраняет тот же `id`.
    func test_inv36c_anonymousAttendeesMergeIntoOnePersonStableAcrossSaves() async throws {
        let repositories = InMemoryRepositories()
        let meeting = try event(
            externalId: "e-anon", organizer: nil, attendees: [try attendee(nil, nil), try attendee(nil, nil)]
        )
        let record = MeetingRecord(event: meeting, dedupKey: nil, status: .scheduled, sources: [])

        try await repositories.meetings.save(record)
        let first = try await repositories.persons.attendees(meetingId: meeting.id)
        let countAfterFirst = repositories.persons.storedRecords.count
        try await repositories.meetings.save(record)
        let second = try await repositories.persons.attendees(meetingId: meeting.id)

        XCTAssertEqual(first.count, 1, "два анонимных участника — один человек, одна строка участия")
        XCTAssertEqual(first.first?.displayName, "", "ни имени, ни адреса — пустой displayName")
        XCTAssertEqual(first.first?.emails, [])
        XCTAssertEqual(countAfterFirst, 1)
        XCTAssertEqual(second.map(\.id), first.map(\.id), "повторный save — тот же id")
        XCTAssertEqual(repositories.persons.storedRecords.count, countAfterFirst, "новых людей не заведено")
    }
}
