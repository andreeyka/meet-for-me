//  К21–К24 — право `.calendars` (C-007), граница перед EventKit. План MEE-343 §2.
//  Четыре пункта — один разбор ветвления: К21/К22 сам факт ветвления, К23 — что реализация
//  ветвится ровно на два случая (`.granted`/не-`.granted`), К24 — расхождение `.granted` с
//  реальностью в момент вызова (развилка Р7).

import DomainCore
import Foundation
import XCTest
@testable import CalendarEventKit

final class PermissionBoundaryTests: XCTestCase {

    func test_k21_deniedRestrictedNotDeterminedBlockBeforeGateway() async throws {
        for status: PermissionStatus in [.denied, .restricted, .notDetermined] {
            let harness = Harness()
            try await harness.initialize()
            harness.permissions.setStatus(status, for: .calendars)

            do {
                _ = try await harness.connector.listCalendars()
                XCTFail("ожидался authorizationRequired для \(status)")
            } catch ConnectorError.authorizationRequired {}
            XCTAssertEqual(harness.gateway.calendarsCallCount, 0, "\(status): шов не тронут")

            do {
                _ = try await harness.connector.fetchEvents(
                    from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000),
                    calendarIds: ["cal-1"]
                )
                XCTFail("ожидался authorizationRequired для \(status)")
            } catch ConnectorError.authorizationRequired {}
            XCTAssertEqual(harness.gateway.eventsCallCount, 0, "\(status): шов не тронут")
        }
    }

    func test_k22_grantedProceedsToGateway() async throws {
        let harness = Harness()
        try await harness.initialize()
        harness.permissions.setStatus(.granted, for: .calendars)

        harness.gateway.setCalendars([.fixture()])
        _ = try await harness.connector.listCalendars()
        XCTAssertEqual(harness.gateway.calendarsCallCount, 1)

        harness.gateway.setEvents([.fixture()])
        _ = try await harness.connector.fetchEvents(
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000),
            calendarIds: ["cal-1"]
        )
        XCTAssertEqual(harness.gateway.eventsCallCount, 1)
    }

    func test_k23_nonGrantedTreatedUniformlyEvenOnDefensiveValues() async throws {
        // Правка возврата РП: предмет — не «порт не отдаёт .unknown» (это инвариант 11 C-007,
        // обязанность порта), а следствие для МОДУЛЯ — ветвление ровно на два случая, значит
        // .unknown и .unavailable (защитные значения, недостижимые верным портом для .calendars)
        // блокируют тем же путём, что и .denied.
        for status: PermissionStatus in [.unknown, .unavailable] {
            let harness = Harness()
            try await harness.initialize()
            harness.permissions.setStatus(status, for: .calendars)

            do {
                _ = try await harness.connector.listCalendars()
                XCTFail("ожидался authorizationRequired для \(status)")
            } catch ConnectorError.authorizationRequired {}
            XCTAssertEqual(harness.gateway.calendarsCallCount, 0, "\(status): Ш1 не тронут")

            // Возврат РП (Д4, 24.09): та же проверка ветвления — и через fetchEvents (Ш2).
            do {
                _ = try await harness.connector.fetchEvents(
                    from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000),
                    calendarIds: ["cal-1"]
                )
                XCTFail("ожидался authorizationRequired для \(status)")
            } catch ConnectorError.authorizationRequired {}
            XCTAssertEqual(harness.gateway.eventsCallCount, 0, "\(status): Ш2 не тронут")
        }
    }

    func test_k24_gatewayFailureAfterGrantedDistinguishesCause() async throws {
        // Возврат РП (Д3, 24.09): вход по перечню — отказ именно на `events(from:to:
        // calendarIds:)`, не на `listCalendars`. Проверено обоими вызовами Ш1 и Ш2.
        let permissionLossHarness = Harness()
        try await permissionLossHarness.initialize()
        permissionLossHarness.permissions.setStatus(.granted, for: .calendars)
        permissionLossHarness.gateway.fail(with: .looksLikePermissionLoss(message: "похоже на потерю права"))
        do {
            _ = try await permissionLossHarness.connector.listCalendars()
            XCTFail("ожидался authorizationRequired, не upstreamUnavailable")
        } catch ConnectorError.authorizationRequired {}
        do {
            _ = try await permissionLossHarness.connector.fetchEvents(
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000),
                calendarIds: ["cal-1"]
            )
            XCTFail("ожидался authorizationRequired, не upstreamUnavailable")
        } catch ConnectorError.authorizationRequired {}

        let otherCauseHarness = Harness()
        try await otherCauseHarness.initialize()
        otherCauseHarness.permissions.setStatus(.granted, for: .calendars)
        otherCauseHarness.gateway.fail(with: .other(message: "иная причина"))
        do {
            _ = try await otherCauseHarness.connector.listCalendars()
            XCTFail("ожидался upstreamUnavailable, не authorizationRequired")
        } catch ConnectorError.upstreamUnavailable(_) {}
        do {
            _ = try await otherCauseHarness.connector.fetchEvents(
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 2_000_000_000),
                calendarIds: ["cal-1"]
            )
            XCTFail("ожидался upstreamUnavailable, не authorizationRequired")
        } catch ConnectorError.upstreamUnavailable(_) {}
    }
}
