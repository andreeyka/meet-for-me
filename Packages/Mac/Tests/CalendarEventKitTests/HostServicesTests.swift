//  К5–К6 — сервисы хоста (C-006 §4/§6, структурная граница). План MEE-343 §2.

import DomainCore
import Foundation
import XCTest
@testable import CalendarEventKit

final class HostServicesTests: XCTestCase {

    func test_k05_noSecretsUsedOverFullLifecycle() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        harness.gateway.setCalendars([.fixture()])
        harness.gateway.setEvents([.fixture()])

        _ = try await harness.connector.listCalendars()
        _ = try await harness.connector.fetchEvents(
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000),
            calendarIds: ["cal-1"]
        )
        await harness.connector.shutdown()

        XCTAssertEqual(harness.host.callCount("secretGet(key:)"), 0, "у EventKit-коннектора нет секрета")
        XCTAssertEqual(harness.host.callCount("secretSet(key:value:)"), 0)
    }

    func test_k06_errorsGoThroughHostLogNotPrintOrNotify() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        harness.gateway.fail(with: .other(message: "внутренняя ошибка чтения событий"))

        do {
            _ = try await harness.connector.fetchEvents(
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000),
                calendarIds: ["cal-1"]
            )
            XCTFail("ожидался upstreamUnavailable")
        } catch ConnectorError.upstreamUnavailable(_) {}

        XCTAssertGreaterThanOrEqual(harness.host.callCount("log(_:_:)"), 1, "диагностика идёт через host.log")
        XCTAssertEqual(harness.host.callCount("notify(_:detail:)"), 0, "push == false — notify не звучит никогда")
    }
}
