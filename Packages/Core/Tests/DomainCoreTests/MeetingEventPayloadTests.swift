//  MeetingEventPayload — конструктор и инварианты C-001 §1 / C-006 §6.1. MEE-346.
//
//  Перебор — по каждому инварианту конструктора отдельным входом, который его нарушает
//  (постановка MEE-346, «Тесты DomainCoreTests»). Инварианты 3 и 5 здесь не перепроверяются
//  отдельно: их держат сами `MeetingEvent.Person` и `MeetingEvent.Conference` (не
//  дублируются, C-006 §6.1), и невалидное значение того или другого типа не доходит до
//  конструктора полезной нагрузки — построить его нечем, оба инициализатора бросающие.
//  Инвариант 6 не несёт ни строки кода: `title: String` значения `nil` не допускает по
//  типу, и входа, который его нарушает, не существует в Swift.
//
//  К списку C-001 добавлены два теста, которые называет сам C-006 §6 обязательными для
//  этого типа: инвариант 15 (ключ `id` в полезной нагрузке — отказ разбора) и инвариант 14
//  (`assigningId` не может отказать по существу — «вычитание пустое»).

import XCTest
@testable import DomainCore

final class MeetingEventPayloadTests: XCTestCase {

    private func makePayload(
        title: String = "T",
        start: Date = date(milliseconds: 1_757_575_800_000),
        end: Date = date(milliseconds: 1_757_579_400_000),
        timeZone: String = "UTC",
        isAllDay: Bool = false,
        organizer: MeetingEvent.Person? = nil,
        attendees: [MeetingEvent.Attendee] = [],
        conference: MeetingEvent.Conference? = nil,
        lastModified: Date = date(milliseconds: 1_757_575_800_000)
    ) throws -> MeetingEventPayload {
        try MeetingEventPayload(
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: title,
            start: start, end: end, timeZone: timeZone, isAllDay: isAllDay, isCancelled: false,
            organizer: organizer, attendees: attendees, location: nil, bodyText: nil,
            conference: conference, lastModified: lastModified
        )
    }

    // MARK: - Инварианты C-001 §1

    func test_invariant1_endBeforeStart_isRejected() {
        XCTAssertNoThrow(try makePayload(
            start: date(milliseconds: 1_000), end: date(milliseconds: 1_000)
        ))
        assertInvariant(
            try makePayload(start: date(milliseconds: 2_000), end: date(milliseconds: 1_000)),
            contract: "C-001", type: "MeetingEventPayload", invariant: 1, path: "end"
        )
    }

    func test_invariant2_timeZone_mustBeIANA() {
        XCTAssertNoThrow(try makePayload(timeZone: "Europe/Moscow"))
        for rejected in ["", "Moscow/Europe", "Russian Standard Time"] {
            assertInvariant(
                try makePayload(timeZone: rejected),
                contract: "C-001", type: "MeetingEventPayload", invariant: 2, path: "timeZone"
            )
        }
    }

    func test_invariant4_duplicateAttendeeAddresses_isRejected() throws {
        let person = try MeetingEvent.Person(name: "Иван", email: "ivan@example.com")
        let attendee = try MeetingEvent.Attendee(person: person, responseStatus: .accepted, isOptional: false)
        assertInvariant(
            try makePayload(attendees: [attendee, attendee]),
            contract: "C-001", type: "MeetingEventPayload", invariant: 4, path: "attendees"
        )
    }

    func test_invariant7_allDayBounds_mustBeStartOfDay() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11)))
        let nextMidnight = midnight.addingTimeInterval(86_400)

        XCTAssertNoThrow(try makePayload(
            start: midnight, end: nextMidnight, timeZone: "UTC", isAllDay: true
        ))
        assertInvariant(
            try makePayload(
                start: midnight.addingTimeInterval(1), end: nextMidnight,
                timeZone: "UTC", isAllDay: true
            ),
            contract: "C-001", type: "MeetingEventPayload", invariant: 7, path: "start"
        )
    }

    /// §0.2 п. 9: `start`, `end`, `lastModified` — единственные три поля этого типа под
    /// ограничением представимости (C-006 §6.1). Сообщается `invariant = 0`, номер
    /// нарушенного инварианта из списка выше — не сообщается, даже если он тоже нарушен.
    func test_invariantZero_dateOutOfRepresentableRange_isRejected() {
        XCTAssertNoThrow(try DateProbe.payload())
        assertInvariant(
            try DateProbe.payload(lastModified: .distantPast),
            contract: "C-001", type: "MeetingEventPayload", invariant: 0, path: "lastModified"
        )
    }

    // MARK: - C-006 §6, инварианты 14 и 15

    /// Инвариант 15: ключ `id` в объекте полезной нагрузки проверяется ДО остальных полей
    /// и даёт отказ разбора, а не тихое игнорирование неизвестного ключа (C-001 §0.4).
    func test_invariant15_idKeyInPayload_isDecodingRejection() throws {
        XCTAssertNoThrow(try decodePayload(PayloadJSON.text()))
        assertCorrupted(try decodePayload(PayloadJSON.text(withId: "\"11111111-1111-4111-8111-111111111111\"")),
                        key: "id")
    }

    /// Инвариант 14: `assigningId` даёт валидный `MeetingEvent` для ЛЮБОГО `uuid` — ни один
    /// инвариант C-001 не ссылается на `id` («вычитание пустое», C-006 §6.1). Тест на это
    /// контракт называет обязательным: он охраняет свойство, на котором держится инвариант 9.
    func test_invariant14_assigningIdNeverFailsOnSubstance() throws {
        let person = try MeetingEvent.Person(name: "Иван", email: "ivan@example.com")
        let attendee = try MeetingEvent.Attendee(person: person, responseStatus: .accepted, isOptional: false)
        let payload = try makePayload(organizer: person, attendees: [attendee])
        for uuid in [UUID(), UUID(), UUID()] {
            let event = try payload.assigningId(uuid)
            XCTAssertEqual(event.id, uuid)
            XCTAssertEqual(event.sourceConnectorId, payload.sourceConnectorId)
            XCTAssertEqual(event.externalId, payload.externalId)
            XCTAssertEqual(event.attendees, payload.attendees)
        }
    }

    /// `init(dropping:)` не бросает и переносит все пятнадцать полей без изменения; `id`
    /// теряется — в самом типе поля для него нет.
    func test_droppingId_copiesEveryFieldButId() throws {
        let event = try DateProbe.event()
        let payload = MeetingEventPayload(dropping: event)
        XCTAssertEqual(payload.sourceConnectorId, event.sourceConnectorId)
        XCTAssertEqual(payload.externalId, event.externalId)
        XCTAssertEqual(payload.title, event.title)
        XCTAssertEqual(payload.start, event.start)
        XCTAssertEqual(payload.end, event.end)
        XCTAssertEqual(payload.timeZone, event.timeZone)
        XCTAssertEqual(payload.lastModified, event.lastModified)
    }
}
