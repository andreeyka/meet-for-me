//  Раздел Д перечня: границы и мусор из реального календаря, пп. 32—37.

import XCTest
import DomainCore

final class MeetingEventBoundaryTests: XCTestCase {

    func test_p32_addressForm_isChecked() throws {
        let rejected = ["\"ivan\"", "\"ivan@\"", "\"@example.com\"", "\"\"", "\"a@b@c\"",
                        "\"iv an@example.com\"", "\"ivan@example.com\\n\"",
                        "\" ivan@example.com\"", "\"Ivan@Example.com\"",
                        "\"mailto:ivan@example.com\""]
        for value in rejected {
            assertInvariant(try decodeEvent(EventJSON.text(
                attendees: "[\(EventJSON.attendee(email: value))]")),
                contract: "C-001", type: "MeetingEvent.Person", invariant: 3, path: "email")
        }
        for value in ["null", "\"ivan@example.com\"", "\"a@b\""] {
            XCTAssertNoThrow(try decodeEvent(EventJSON.text(
                attendees: "[\(EventJSON.attendee(email: value))]")), value)
        }
    }

    /// Участник и организатор по четырём полям неразличимы: `Person` сообщает о себе сам,
    /// и индекс участника в ошибку не попадает вовсе.
    func test_p32_attendeeAndOrganizer_areIndistinguishable() throws {
        let bad = "\"ivan\""
        let fromAttendee = errorOf(try decodeEvent(EventJSON.text(
            attendees: "[\(EventJSON.attendee(email: bad))]")))
        let fromOrganizer = errorOf(try decodeEvent(EventJSON.text(
            organizer: EventJSON.person(email: bad))))
        XCTAssertEqual(fromAttendee, fromOrganizer)
        XCTAssertEqual(fromAttendee?.path, "email")
    }

    func test_p33_unknownResponseStatus_readsAsUnknown() throws {
        for raw in ["\"delegated\"", "\"ACCEPTED\"", "\"\""] {
            let decoded = try decodeEvent(EventJSON.text(
                attendees: "[\(EventJSON.attendee(email: "null", status: raw))]"))
            XCTAssertEqual(decoded.attendees.first?.responseStatus, .unknown, raw)
        }
        let decoded = try decodeEvent(EventJSON.text(
            attendees: "[\(EventJSON.attendee(email: "null", status: "\"delegated\""))]"))
        let text = try encodedText(decoded)
        XCTAssertTrue(text.contains("\"unknown\""))
        XCTAssertFalse(text.contains("delegated"))
    }

    func test_p34_unknownProvider_isAccepted() throws {
        for provider in ["\"skype\"", "\"\"", "\"\(String(repeating: "x", count: 300))\""] {
            XCTAssertNoThrow(try decodeEvent(EventJSON.text(
                conference: EventJSON.conference(provider: provider))), provider)
        }
    }

    func test_p35_allDayBounds_areFirstInstantOfDay() throws {
        XCTAssertNoThrow(try decodeEvent(allDay(zone: "\"Europe/Moscow\"",
                                                start: "\"2026-09-10T21:00:00.000Z\"",
                                                end: "\"2026-09-11T21:00:00.000Z\"")))
        XCTAssertNoThrow(try decodeEvent(allDay(zone: "\"Asia/Beirut\"",
                                                start: "\"2026-03-28T22:00:00.000Z\"",
                                                end: "\"2026-03-29T21:00:00.000Z\"")))
        assertInvariant(try decodeEvent(allDay(zone: "\"Europe/Moscow\"",
                                               start: "\"2026-09-11T07:00:00.000Z\"",
                                               end: "\"2026-09-11T21:00:00.000Z\"")),
                        contract: "C-001", type: "MeetingEvent", invariant: 7, path: "start")
        assertInvariant(try decodeEvent(allDay(zone: "\"Europe/Moscow\"",
                                               start: "\"2026-09-10T21:00:00.000Z\"",
                                               end: "\"2026-09-10T21:00:00.000Z\"")),
                        contract: "C-001", type: "MeetingEvent", invariant: 7, path: "end")
        assertInvariant(try decodeEvent(allDay(zone: "\"Europe/Moscow\"",
                                               start: "\"2026-09-11T00:00:00.000Z\"",
                                               end: "\"2026-09-11T21:00:00.000Z\"")),
                        contract: "C-001", type: "MeetingEvent", invariant: 7, path: "start")
    }

    /// Односторонность: `isAllDay == false` с границами на первом мгновении суток — принято.
    func test_p35_notAllDayWithMidnightBounds_isAccepted() throws {
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(
            start: "\"2026-09-10T21:00:00.000Z\"", end: "\"2026-09-11T21:00:00.000Z\"",
            timeZone: "\"Europe/Moscow\"", isAllDay: "false")))
    }

    func test_p36_lastModified_hasNoRelationToBounds() throws {
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(
            lastModified: "\"2025-09-10T12:00:00.000Z\"")))
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(
            lastModified: "\"9999-12-31T23:59:59.999Z\"")))
    }

    func test_p37_bodyTextWithMarkup_isAcceptedAsIs() throws {
        let decoded = try decodeEvent(EventJSON.text(bodyText: "\"<p>привет</p>\""))
        XCTAssertEqual(decoded.bodyText, "<p>привет</p>")
    }

    private func allDay(zone: String, start: String, end: String) -> String {
        EventJSON.text(start: start, end: end, timeZone: zone, isAllDay: "true")
    }

    private func errorOf<Value>(_ expression: @autoclosure () throws -> Value)
    -> DomainValidationError? {
        do {
            _ = try expression()
            return nil
        } catch {
            return error as? DomainValidationError
        }
    }
}
