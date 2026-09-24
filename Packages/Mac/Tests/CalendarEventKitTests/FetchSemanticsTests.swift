//  К19–К20 — получение событий: развёртка повторений и окно выборки (C-006 §3, «Что вне
//  контракта»; развилка Р9). План MEE-343 §2, подраздел 2.

import DomainCore
import Foundation
import XCTest
@testable import CalendarEventKit

final class FetchSemanticsTests: XCTestCase {

    func test_k19_recurringEventExpandedIntoSeparateEntries() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        // Уже развёрнутые источником (шов, Ш2) три вхождения одного повторяющегося события —
        // каждое со своим externalId (М1 калибрует, что живой EventKit действительно так делает).
        let occurrences = (0..<3).map { index in
            RawEvent.fixture(
                externalId: "evt-recur-\(index)",
                start: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 86_400),
                end: Date(timeIntervalSince1970: 1_700_003_600 + Double(index) * 86_400)
            )
        }
        harness.gateway.setEvents(occurrences)

        let payloads = try await harness.connector.fetchEvents(
            from: Date(timeIntervalSince1970: 1_699_000_000), to: Date(timeIntervalSince1970: 1_701_000_000),
            calendarIds: ["cal-1"]
        )
        XCTAssertEqual(payloads.count, 3)
        XCTAssertEqual(Set(payloads.map(\.externalId)).count, 3, "каждое вхождение — свой externalId")
    }

    func test_k20_windowHalfOpenAndCalendarIdsFilter() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_100_000)
        // Возврат РП (Д5, 24.09): пять календарей, как в перечне (МЕЕ-339, вход К20) — только
        // два из пяти запрошены.
        harness.gateway.setEvents([
            .fixture(calendarId: "id1", externalId: "evt-t1", start: t1, end: t1.addingTimeInterval(3_600)),
            .fixture(calendarId: "id1", externalId: "evt-t2", start: t2, end: t2.addingTimeInterval(3_600)),
            .fixture(
                calendarId: "id3", externalId: "evt-other-cal",
                start: t1.addingTimeInterval(1_000), end: t1.addingTimeInterval(2_000)
            ),
            .fixture(
                calendarId: "id2", externalId: "evt-outside",
                start: t2.addingTimeInterval(10_000), end: t2.addingTimeInterval(11_000)
            ),
            .fixture(
                calendarId: "id4", externalId: "evt-id4",
                start: t1.addingTimeInterval(1_500), end: t1.addingTimeInterval(2_500)
            ),
            .fixture(
                calendarId: "id5", externalId: "evt-id5",
                start: t1.addingTimeInterval(1_800), end: t1.addingTimeInterval(2_800)
            )
        ])

        let payloads = try await harness.connector.fetchEvents(from: t1, to: t2, calendarIds: ["id1", "id2"])
        let ids = Set(payloads.map(\.externalId))
        XCTAssertTrue(ids.contains("evt-t1"), "T1 включена — левая граница")
        XCTAssertFalse(ids.contains("evt-t2"), "T2 исключена — правая граница")
        XCTAssertFalse(ids.contains("evt-other-cal"), "календарь id3 не запрошен")
        XCTAssertFalse(ids.contains("evt-outside"), "событие вне окна")
        XCTAssertFalse(ids.contains("evt-id4"), "календарь id4 не запрошен")
        XCTAssertFalse(ids.contains("evt-id5"), "календарь id5 не запрошен")
    }
}
