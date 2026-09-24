//  К10–К18 — получение событий, нормализация полей (C-006 §6.1, инв. 9, 13, 14; C-001 §1,
//  §0.2 п. 9, «Поведение»). План MEE-343 §2, подраздел 1. Все девять — на входе
//  `EventKitGateway`, отдающем СЫРЫЕ поля источника; ответ проверяется на построенном
//  `MeetingEventPayload`.

import DomainCore
import Foundation
import XCTest
@testable import CalendarEventKit

final class NormalizationTests: XCTestCase {

    private let wideFrom = Date(timeIntervalSince1970: 0)
    private let wideTo = Date(timeIntervalSinceReferenceDate: 4e11)

    private func fetch(_ harness: Harness) async throws -> [MeetingEventPayload] {
        try await harness.connector.fetchEvents(from: wideFrom, to: wideTo, calendarIds: ["cal-1"])
    }

    func test_k10_emailLowercasedAndMailtoStripped() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        harness.gateway.setEvents([.fixture(attendees: [
            .fixture(person: RawPerson(name: "A", email: "Name@EXAMPLE.com")),
            .fixture(person: RawPerson(name: "B", email: "mailto:User@Example.org"))
        ])])

        let payloads = try await fetch(harness)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].attendees[0].person.email, "name@example.com")
        XCTAssertEqual(payloads[0].attendees[1].person.email, "user@example.org")
    }

    func test_k11_syntacticallyInvalidEmailBecomesNil() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        harness.gateway.setEvents([.fixture(attendees: [
            .fixture(person: RawPerson(name: "Без собаки", email: "no-at-sign")),
            .fixture(person: RawPerson(name: "С пробелом", email: "with space@example.com"))
        ])])

        let payloads = try await fetch(harness)
        XCTAssertEqual(payloads.count, 1, "событие не теряется целиком из-за негодного адреса")
        XCTAssertNil(payloads[0].attendees[0].person.email)
        XCTAssertNil(payloads[0].attendees[1].person.email)
    }

    func test_k12_timeZoneMustBeValidIANA() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        harness.gateway.setEvents([
            .fixture(externalId: "evt-bad-zone", timeZoneIdentifier: "Not/AZone"),
            .fixture(externalId: "evt-good-zone", timeZoneIdentifier: "Europe/Moscow")
        ])

        let payloads = try await fetch(harness)
        let bad = try XCTUnwrap(payloads.first { $0.externalId == "evt-bad-zone" })
        XCTAssertNotNil(TimeZone(identifier: bad.timeZone))
        let good = try XCTUnwrap(payloads.first { $0.externalId == "evt-good-zone" })
        XCTAssertEqual(good.timeZone, "Europe/Moscow", "валидный идентификатор переносится без изменения")
    }

    func test_k13_allDayEndAtNextDayStart() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        // 2024-01-01T00:00:00Z … 2024-01-01T23:59:59.999Z — «Поведение» C-001, дословно
        // измеренное EventKit (M1 калибрует факт на живом Mac; здесь — уже заявленный вход).
        let rawStart = Date(timeIntervalSince1970: 1_704_067_200)
        let rawEnd = Date(timeIntervalSince1970: 1_704_153_599.999)
        harness.gateway.setEvents([.fixture(
            start: rawStart, end: rawEnd, timeZoneIdentifier: "UTC", isAllDay: true
        )])

        let payloads = try await fetch(harness)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].start, rawStart)
        XCTAssertEqual(payloads[0].end, Date(timeIntervalSince1970: 1_704_153_600), "первое мгновение СЛЕДУЮЩИХ суток")
        XCTAssertGreaterThan(payloads[0].end, payloads[0].start)
    }

    func test_k14_allDayDSTDayWithoutMidnight() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        // Тот же день, что седьмая фикстура C-001 (`MeetingEventFixtures.allDayWithoutMidnight`,
        // Asia/Beirut, 29.03) — сутки без полуночи (переход на летнее время). Сырой `end` —
        // произвольный момент ВНУТРИ того же календарного дня (10 часов от начала), а не
        // фиксированный сдвиг в секундах: `Calendar.startOfDay`/`date(byAdding:.day)` сами
        // учитывают укороченные сутки, простая арифметика в секундах — нет.
        let rawStart = Date(timeIntervalSince1970: 1_774_735_200)
        let rawEnd = rawStart.addingTimeInterval(10 * 3600)
        harness.gateway.setEvents([.fixture(
            start: rawStart, end: rawEnd, timeZoneIdentifier: "Asia/Beirut", isAllDay: true
        )])

        let payloads = try await fetch(harness)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].start, rawStart, "не побитовая проверка «00:00» — startOfDay совпал с сырым")
        // Независимое значение — то же самое, что несёт принятая фикстура C-001 для этого дня.
        XCTAssertEqual(payloads[0].end, Date(timeIntervalSince1970: 1_774_818_000))
        XCTAssertEqual(payloads[0].end.timeIntervalSince(payloads[0].start), 23 * 3600, "сутки короче на час — DST")
    }

    func test_k15_duplicateAttendeeEmailFailsWholeFetchCall() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        let validEvent = RawEvent.fixture(externalId: "evt-valid")
        let duplicateEvent = RawEvent.fixture(externalId: "evt-dup", attendees: [
            .fixture(person: RawPerson(name: "A", email: "A@x.com")),
            .fixture(person: RawPerson(name: "B", email: "mailto:a@x.com"))
        ])
        harness.gateway.setEvents([validEvent, duplicateEvent])

        do {
            _ = try await fetch(harness)
            XCTFail("ожидался protocolViolation для ВСЕГО вызова, включая валидное первое событие")
        } catch ConnectorError.protocolViolation(_) {}
    }

    /// Ждёт C-009 (IR-118, MEE-348, возврат РП на MEE-349, 24.09): К16 в этом виде — тест
    /// временной эвристики Р4 (`EventNormalizer.detectConference`), не финального поведения.
    /// РП: «в нынешнем виде (таблица доменов) К16 принят не будет». Тест остаётся зелёным,
    /// пока `EventKitConnector.resolveConference` не переключат на `platformResolver`
    /// (см. `// СТРОКА:` там же) — замена этого теста идёт той же правкой.
    func test_k16_conferenceHeuristicMatchesKnownProviderAndAbsence() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        harness.gateway.setEvents([
            .fixture(externalId: "evt-zoom", location: "https://zoom.us/j/123456789"),
            .fixture(externalId: "evt-none", location: "Переговорка 3")
        ])

        let payloads = try await fetch(harness)
        let zoomPayload = try XCTUnwrap(payloads.first { $0.externalId == "evt-zoom" })
        XCTAssertEqual(zoomPayload.conference?.provider, "zoom")
        XCTAssertEqual(zoomPayload.conference?.joinUrl.absoluteString, "https://zoom.us/j/123456789")
        let nonePayload = try XCTUnwrap(payloads.first { $0.externalId == "evt-none" })
        XCTAssertNil(nonePayload.conference, "нет узнаваемой ссылки — не отказ")
    }

    func test_k17_dateRepresentabilityThreeFieldsGroup() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        let farFuture = Date(timeIntervalSinceReferenceDate: 3e11)   // далеко за 9999-12-31

        let cases: [(label: String, event: RawEvent)] = [
            ("start", .fixture(externalId: "evt-start", start: farFuture, end: farFuture.addingTimeInterval(3600))),
            ("end", .fixture(externalId: "evt-end", end: farFuture)),
            ("lastModified", .fixture(externalId: "evt-lastmod", lastModified: farFuture))
        ]
        for testCase in cases {
            harness.gateway.setEvents([testCase.event])
            do {
                _ = try await fetch(harness)
                XCTFail("ожидался отказ представимости, поле \(testCase.label)")
            } catch ConnectorError.protocolViolation(let message) {
                XCTAssertTrue(message.contains("инв. 0"), "поле \(testCase.label): \(message)")
            }
        }
    }

    func test_k18_cancelledEventFieldsPreservedInFull() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        harness.gateway.setEvents([.fixture(
            isCancelled: true, organizer: .fixture(name: "Организатор"),
            attendees: [.fixture()], location: "Zoom", notes: "Заметки"
        )])

        let payloads = try await fetch(harness)
        XCTAssertEqual(payloads.count, 1)
        XCTAssertTrue(payloads[0].isCancelled)
        XCTAssertNotNil(payloads[0].organizer, "поля переносятся как у неотменённого события")
        XCTAssertEqual(payloads[0].attendees.count, 1)
        XCTAssertEqual(payloads[0].location, "Zoom")
        XCTAssertEqual(payloads[0].bodyText, "Заметки")
    }
}
