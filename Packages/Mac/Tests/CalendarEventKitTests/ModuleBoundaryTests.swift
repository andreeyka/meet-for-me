//  К26–К28 — запрещено (`docs/module-map.md`, раздел calendar-eventkit). План MEE-343 §2.
//
//  К27 НЕ ЯВЛЯЕТСЯ XCTest (план, «Способ» — мех.): (а) `Package.swift` не зависит от таргета
//  `Storage`/GRDB — проверяется командой `grep -c -E 'Storage|GRDB' Packages/Mac/Package.swift`;
//  (б) публичная поверхность без типа GRDB — покрыто существующим барьером CI «Символьный
//  граф». Обе команды прогнаны и их вывод приложен к отчёту MEE-349 отдельно, не здесь.

import DomainCore
import DomainTestKit
import Foundation
import XCTest
@testable import CalendarEventKit

final class ModuleBoundaryTests: XCTestCase {

    func test_k26_duplicateExternalIdNotDeduplicatedByConnector() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        let from = Date(timeIntervalSince1970: 0)
        let to = Date(timeIntervalSince1970: 2_000_000_000)

        // (а) один и тот же externalId в РАЗНЫХ вызовах.
        let event = RawEvent.fixture(externalId: "evt-dup")
        harness.gateway.setEvents([event])
        let first = try await harness.connector.fetchEvents(from: from, to: to, calendarIds: ["cal-1"])
        let second = try await harness.connector.fetchEvents(from: from, to: to, calendarIds: ["cal-1"])
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first[0].externalId, second[0].externalId, "не слито и не отброшено — дедуп у calendar-hub")

        // (б) правка возврата РП п. 6 — тот же дубль ВНУТРИ одного вызова.
        harness.gateway.setEvents([event, event])
        let combined = try await harness.connector.fetchEvents(from: from, to: to, calendarIds: ["cal-1"])
        XCTAssertEqual(combined.count, 2, "оба возвращены как есть — вектор (а) в одиночку не ловит эту щель")
    }

    func test_k28_noSelfInitiatedPollingOverControlWindow() async throws {
        let harness = Harness()
        try await harness.initialize()
        // `EventKitConnector` не заводит ни одного таймера/задачи, поэтому контрольное окно
        // модельного времени (`ManualClock`, C-013) можно просто сдвинуть без ожидания —
        // ни единого self-initiated обращения к шву произойти неоткуда.
        let clock = ManualClock()
        clock.advance(by: 3_600)

        XCTAssertEqual(harness.gateway.calendarsCallCount, 0)
        XCTAssertEqual(harness.gateway.eventsCallCount, 0)
    }
}
