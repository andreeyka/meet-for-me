//  К25 — `healthCheck` (C-006 §6; развилка Р5). План MEE-343 §2.

import DomainCore
import Foundation
import XCTest
@testable import CalendarEventKit

final class HealthCheckTests: XCTestCase {

    func test_k25_healthStatusFourCombinations() async throws {
        // (1) .granted + последний вызов успешен → .ok
        do {
            let harness = Harness()
            try await harness.initialize()
            harness.permissions.setStatus(.granted, for: .calendars)
            harness.gateway.setCalendars([.fixture()])
            _ = try await harness.connector.listCalendars()

            let health = try await harness.connector.healthCheck()
            XCTAssertEqual(health.status, .ok)
            XCTAssertNotNil(health.lastSuccessfulSyncAt)
        }
        // (2) .granted + последний вызов отказал → .failed, причина в message
        do {
            let harness = Harness()
            try await harness.initialize()
            harness.permissions.setStatus(.granted, for: .calendars)
            harness.gateway.fail(with: .other(message: "отказ шва"))
            _ = try? await harness.connector.listCalendars()

            let health = try await harness.connector.healthCheck()
            XCTAssertEqual(health.status, .failed)
            XCTAssertNotNil(health.message)
            XCTAssertNil(health.lastSuccessfulSyncAt, "успеха не было ни разу")
        }
        // (3) не .granted, хотя раньше был успешный вызов → .failed, метка успеха сохраняется
        do {
            let harness = Harness()
            try await harness.initialize()
            harness.permissions.setStatus(.granted, for: .calendars)
            harness.gateway.setCalendars([.fixture()])
            _ = try await harness.connector.listCalendars()
            harness.permissions.setStatus(.denied, for: .calendars)

            let health = try await harness.connector.healthCheck()
            XCTAssertEqual(health.status, .failed)
            XCTAssertNotNil(health.lastSuccessfulSyncAt, "историческая метка успеха не стирается отзывом права")
            XCTAssertNotNil(health.message, "возврат РП (Д6, 24.09): причина названа и здесь")
        }
        // (4) не .granted, вызовов шва не было вовсе → .failed, lastSuccessfulSyncAt == nil
        do {
            let harness = Harness()
            try await harness.initialize()
            harness.permissions.setStatus(.denied, for: .calendars)

            let health = try await harness.connector.healthCheck()
            XCTAssertEqual(health.status, .failed)
            XCTAssertNil(health.lastSuccessfulSyncAt)
            XCTAssertNotNil(health.message, "возврат РП (Д6, 24.09): причина названа и здесь")
        }
    }
}
