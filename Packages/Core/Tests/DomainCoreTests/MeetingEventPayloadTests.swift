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
//
//  ВОЗВРАТ РП (24.09, MEE-346). Дописаны: лестница ступеней (а)→(в)→(б) — вход, где
//  инварианты 1, 2, 4 и 7 нарушены ОДНОВРЕМЕННО с непредставимой датой, обязан отвечать
//  `invariant = 0`, а не номером нарушенного инварианта списка выше (C-006 §6.1 называет
//  этот вектор прямо); остальные входы инварианта 7 (граница по `end`, `end == start`,
//  сутки Бейрута без локальной полуночи — переход на летнее время там сдвигает 00:00
//  вперёд, и такого момента у суток попросту нет); `start`, `end` и верхняя граница
//  диапазона §0.2 п. 9 для инварианта 0.

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

    /// Симметрия с `start` выше: граница нарушена на `end`, а не на `start`.
    func test_invariant7_endNotStartOfDay_isRejected() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11)))
        let nextMidnight = midnight.addingTimeInterval(86_400)

        assertInvariant(
            try makePayload(
                start: midnight, end: nextMidnight.addingTimeInterval(-1),
                timeZone: "UTC", isAllDay: true
            ),
            contract: "C-001", type: "MeetingEventPayload", invariant: 7, path: "end"
        )
    }

    /// `end == start` — оба на начале суток, но событие на весь день обязано занимать
    /// хотя бы одни сутки: «`end` не больше `start`» — тоже отказ по `end`.
    func test_invariant7_endEqualsStart_isRejected() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11)))

        assertInvariant(
            try makePayload(start: midnight, end: midnight, timeZone: "UTC", isAllDay: true),
            contract: "C-001", type: "MeetingEventPayload", invariant: 7, path: "end"
        )
    }

    /// Бейрут переводит часы вперёд РОВНО в 00:00 местного времени: у суток перехода
    /// локального `00:00:00` не существует вовсе — сутки начинаются с первого момента,
    /// который `startOfDay(for:)` фактически считает началом. День перехода ищется
    /// перебором (не датой руками): правило Бейрута менялось (2023) и вправе поменяться
    /// снова, а проверяемое свойство — «сутки без 00:00», а не конкретное число.
    private func firstDayWithoutLocalMidnight(
        in year: Int, zone: TimeZone, calendar: Calendar
    ) throws -> Date {
        var probe = try XCTUnwrap(calendar.date(from: DateComponents(year: year, month: 1, day: 1, hour: 12)))
        for _ in 0..<366 {
            let dayStart = calendar.startOfDay(for: probe)
            if calendar.component(.hour, from: dayStart) != 0 {
                return dayStart
            }
            probe = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: probe))
        }
        return try XCTUnwrap(nil, "в \(year) году в \(zone.identifier) не нашлось суток без локальной полуночи")
    }

    func test_invariant7_beirutDstDayWithoutLocalMidnight_isAccepted() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Beirut"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = try firstDayWithoutLocalMidnight(in: 2026, zone: zone, calendar: calendar)
        XCTAssertNotEqual(calendar.component(.hour, from: start), 0,
                          "вектор непустоты: сутки действительно без локальной полуночи")
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))

        XCTAssertNoThrow(try makePayload(start: start, end: end, timeZone: "Asia/Beirut", isAllDay: true))
    }

    /// То же граничное значение Бейрута, но через `init(dropping:)`: путь другой
    /// (значения уже проверил `MeetingEvent.init`), значения — те же, и они переживают его
    /// без изменения.
    func test_invariant7_beirutBoundsSurviveInitDropping() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Beirut"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = try firstDayWithoutLocalMidnight(in: 2026, zone: zone, calendar: calendar)
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))

        let event = try MeetingEvent(
            id: UUID(), sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: start, end: end, timeZone: "Asia/Beirut", isAllDay: true, isCancelled: false,
            organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: start
        )
        let payload = MeetingEventPayload(dropping: event)
        XCTAssertEqual(payload.start, start)
        XCTAssertEqual(payload.end, end)
        XCTAssertTrue(payload.isAllDay)
    }

    // MARK: - Лестница ступеней (а)→(в)→(б): представимость раньше собственных инвариантов

    /// C-006 §6.1 называет этот вектор прямо: инвариант 1 нарушен ОДНОВРЕМЕННО с непредставимой
    /// датой — отвечает `invariant = 0`, а не 1. `lastModified` проверяется третьим по счёту
    /// (после `start`/`end`), и оба они здесь валидны — отказ приходит именно с него.
    func test_ladder_representabilityWinsOverInvariant1() {
        assertInvariant(
            try makePayload(
                start: date(milliseconds: 2_000), end: date(milliseconds: 1_000),
                lastModified: .distantPast
            ),
            contract: "C-001", type: "MeetingEventPayload", invariant: 0, path: "lastModified"
        )
    }

    func test_ladder_representabilityWinsOverInvariant2() {
        assertInvariant(
            try makePayload(timeZone: "не-IANA", lastModified: .distantPast),
            contract: "C-001", type: "MeetingEventPayload", invariant: 0, path: "lastModified"
        )
    }

    func test_ladder_representabilityWinsOverInvariant4() throws {
        let person = try MeetingEvent.Person(name: "Иван", email: "ivan@example.com")
        let attendee = try MeetingEvent.Attendee(person: person, responseStatus: .accepted, isOptional: false)
        assertInvariant(
            try makePayload(attendees: [attendee, attendee], lastModified: .distantPast),
            contract: "C-001", type: "MeetingEventPayload", invariant: 0, path: "lastModified"
        )
    }

    func test_ladder_representabilityWinsOverInvariant7() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 11)))
        let nextMidnight = midnight.addingTimeInterval(86_400)

        assertInvariant(
            try makePayload(
                start: midnight.addingTimeInterval(1), end: nextMidnight,
                timeZone: "UTC", isAllDay: true, lastModified: .distantPast
            ),
            contract: "C-001", type: "MeetingEventPayload", invariant: 0, path: "lastModified"
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

    /// Симметрия с `lastModified` выше: `start` тоже под ограничением представимости.
    func test_invariantZero_startOutOfRepresentableRange_isRejected() {
        assertInvariant(
            try DateProbe.payload(start: .distantPast),
            contract: "C-001", type: "MeetingEventPayload", invariant: 0, path: "start"
        )
    }

    /// Симметрия с `lastModified` выше: `end` тоже под ограничением представимости.
    func test_invariantZero_endOutOfRepresentableRange_isRejected() {
        assertInvariant(
            try DateProbe.payload(end: .distantPast),
            contract: "C-001", type: "MeetingEventPayload", invariant: 0, path: "end"
        )
    }

    /// Верхняя граница диапазона §0.2 п. 9: `9999-12-31T23:59:59.999Z` — последнее
    /// представимое значение, значение за ней уже отказ. `.distantFuture` для верхней
    /// границы не годится: он лежит В диапазоне (проверено `CalendarAndRangeTests`,
    /// п. 126) — граница берётся из `DomainDateGrammar` тем же счётом, что и запись байтов.
    func test_invariantZero_dateAboveUpperBound_isRejected() {
        XCTAssertNoThrow(try DateProbe.payload(end: DomainDateGrammar.upperBound))
        assertInvariant(
            try DateProbe.payload(end: DomainDateGrammar.upperBound.addingTimeInterval(1)),
            contract: "C-001", type: "MeetingEventPayload", invariant: 0, path: "end"
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
