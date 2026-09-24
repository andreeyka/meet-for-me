//  К7–К9 — список календарей и схема настроек (C-006 §3/§6). План MEE-343 §2.

import DomainCore
import Foundation
import XCTest
@testable import CalendarEventKit

final class CalendarsAndSettingsTests: XCTestCase {

    func test_k07_listCalendarsMapsFieldsDirectly() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        let source = [
            RawCalendar.fixture(calendarId: "cal-1", title: "Личный", isReadOnly: false),
            RawCalendar.fixture(calendarId: "cal-2", title: "Рабочий", isReadOnly: false),
            RawCalendar.fixture(calendarId: "cal-3", title: "Праздники", isReadOnly: true)
        ]
        harness.gateway.setCalendars(source)

        let result = try await harness.connector.listCalendars()
        XCTAssertEqual(result.count, 3)
        for (raw, mapped) in zip(source, result) {
            XCTAssertEqual(mapped.calendarId, raw.calendarId)
            XCTAssertEqual(mapped.title, raw.title)
            XCTAssertEqual(mapped.isReadOnly, raw.isReadOnly)
        }
    }

    func test_k08_listCalendarsEmptyIsNotAnError() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        harness.gateway.setCalendars([])

        let result = try await harness.connector.listCalendars()
        XCTAssertEqual(result, [])
    }

    func test_k09_settingsSchemaEmptyObjectAndConfigureAccepts() async throws {
        let harness = Harness()
        try await harness.initialize()

        let schemaData = try await harness.connector.settingsSchema()
        let parsed = try JSONSerialization.jsonObject(with: schemaData) as? [String: Any]
        XCTAssertEqual(parsed?["type"] as? String, "object")
        XCTAssertNotNil(parsed?["properties"] as? [String: Any])

        try await harness.connector.configure(settings: Data("{}".utf8))
    }
}
