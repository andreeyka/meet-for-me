//  Раздел Г перечня: инварианты C-001, пп. 22—31.

import XCTest
import DomainCore

final class MeetingEventTests: XCTestCase {

    func test_p22_endBeforeStart_isRejected() throws {
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(start: "\"2026-09-11T09:30:00.000Z\"",
                                                        end: "\"2026-09-11T09:30:00.000Z\"")))
        assertInvariant(try decodeEvent(EventJSON.text(start: "\"2026-09-11T09:30:00.001Z\"",
                                                       end: "\"2026-09-11T09:30:00.000Z\"")),
                        contract: "C-001", type: "MeetingEvent", invariant: 1, path: "end")
    }

    func test_p23_timeZone_mustBeIANA() throws {
        for accepted in ["\"Europe/Moscow\"", "\"UTC\""] {
            XCTAssertNoThrow(try decodeEvent(EventJSON.text(timeZone: accepted)), accepted)
        }
        for rejected in ["\"\"", "\"Moscow/Europe\"", "\"Russian Standard Time\""] {
            assertInvariant(try decodeEvent(EventJSON.text(timeZone: rejected)),
                            contract: "C-001", type: "MeetingEvent", invariant: 2, path: "timeZone")
        }
    }

    func test_p24_emailIsNotRepairedSilently() throws {
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(
            attendees: "[\(EventJSON.attendee(email: "null"))]")))
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(
            attendees: "[\(EventJSON.attendee(email: "\"ivan@example.com\""))]")))
        for rejected in ["\"Ivan@Example.com\"", "\"mailto:ivan@example.com\""] {
            assertInvariant(try decodeEvent(EventJSON.text(
                attendees: "[\(EventJSON.attendee(email: rejected))]")),
                contract: "C-001", type: "MeetingEvent.Person", invariant: 3, path: "email")
        }
    }

    func test_p25_duplicateAddress_isRejected() throws {
        let same = "[\(EventJSON.attendee(email: "\"ivan@example.com\"")), " +
            "\(EventJSON.attendee(email: "\"ivan@example.com\""))]"
        assertInvariant(try decodeEvent(EventJSON.text(attendees: same)),
                        contract: "C-001", type: "MeetingEvent", invariant: 4, path: "attendees")
    }

    /// Сравнение посимвольное: дедуп не «умничает» с точками в локальной части.
    func test_p25_similarAddresses_areAccepted() throws {
        let pair = "[\(EventJSON.attendee(email: "\"i.van@x.ru\"")), " +
            "\(EventJSON.attendee(email: "\"ivan@x.ru\""))]"
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(attendees: pair)))
    }

    func test_p26_nilAddressesWithSameName_areAccepted() throws {
        let pair = "[\(EventJSON.attendee(email: "null")), \(EventJSON.attendee(email: "null"))]"
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(attendees: pair)))
    }

    func test_p27_emptyAttendees_isAccepted() throws {
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(attendees: "[]")))
    }

    func test_p28_joinUrl_mustBeAbsoluteHTTPS() throws {
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(
            conference: EventJSON.conference(joinUrl: "\"https://zoom.us/j/123\""))))
        for rejected in ["\"http://zoom.us/j/123\"", "\"zoom.us/j/123\"",
                         "\"zoommtg://zoom.us/join?confno=123\""] {
            assertInvariant(try decodeEvent(EventJSON.text(
                conference: EventJSON.conference(joinUrl: rejected))),
                contract: "C-001", type: "MeetingEvent.Conference", invariant: 5, path: "joinUrl")
        }
    }

    func test_p29_emptyTitle_isAcceptedMissingKeyIsNot() throws {
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(title: "\"\"")))
        let stripped = EventJSON.text().replacingOccurrences(of: "\"title\": \"Синхронизация\", ",
                                                             with: "")
        assertKeyNotFound(try decodeEvent(stripped), key: "title")
    }

    func test_p30_missingId_isRejected() throws {
        let stripped = EventJSON.text()
            .replacingOccurrences(of: "\"id\": \(EventJSON.identifier), ", with: "")
        assertKeyNotFound(try decodeEvent(stripped), key: "id")
    }

    func test_p31_optionalMembers_areAccepted() throws {
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(conference: "null", organizer: "null")))
        let sparse = EventJSON.conference(tail: "")
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(conference: sparse)))
        let decoded = try decodeEvent(EventJSON.text(conference: sparse))
        XCTAssertNil(decoded.conference?.meetingId)
        XCTAssertNil(decoded.conference?.passcode)
        XCTAssertNil(decoded.organizer)
    }
}
