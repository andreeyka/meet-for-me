//  К1–К4 — инициализация, capabilities, жизненный цикл (C-006 §6, инв. 1, 6, 7). План MEE-343 §2.

import DomainCore
import Foundation
import XCTest
@testable import CalendarEventKit

final class InitializationTests: XCTestCase {

    func test_k01_initializeReturnsFixedCapabilities() async throws {
        let harness = Harness()
        let (info, capabilities) = try await harness.initialize(connectorInstanceId: "любая-строка")
        XCTAssertFalse(info.id.isEmpty)
        XCTAssertFalse(info.name.isEmpty)
        XCTAssertFalse(info.version.isEmpty)
        // Р1–Р4 дословно.
        XCTAssertEqual(capabilities.deltaSync, false)
        XCTAssertEqual(capabilities.push, false)
        XCTAssertEqual(capabilities.attendees, true)
        XCTAssertEqual(capabilities.conference, true)
        XCTAssertEqual(capabilities.auth, .none)

        // `capabilities`/`PluginInfo` не зависят от входа — другой connectorInstanceId даёт то же.
        let (info2, capabilities2) = try await harness.initialize(connectorInstanceId: "другая-строка")
        XCTAssertEqual(info, info2)
        XCTAssertEqual(capabilities, capabilities2)
    }

    func test_k02_authMethodsUnreachableAtAuthNone() async throws {
        let harness = Harness()
        try await harness.initialize()

        do {
            _ = try await harness.connector.beginAuth()
            XCTFail("ожидался protocolViolation")
        } catch ConnectorError.protocolViolation(_) {}

        do {
            _ = try await harness.connector.completeAuth(callbackUrl: URL(string: "https://example.com")!)
            XCTFail("ожидался protocolViolation")
        } catch ConnectorError.protocolViolation(_) {}
    }

    func test_k03_fetchChangesUnreachableAtDeltaSyncFalse() async throws {
        let harness = Harness()
        try await harness.initialize()

        for cursor in [nil, "непустая-строка-курсора"] {
            do {
                _ = try await harness.connector.fetchChanges(cursor: cursor, calendarIds: ["cal-1"])
                XCTFail("ожидался protocolViolation для cursor=\(String(describing: cursor))")
            } catch ConnectorError.protocolViolation(_) {}
        }
        XCTAssertEqual(harness.gateway.eventsCallCount, 0, "fetchChanges не должен трогать шов ни разу")
    }

    func test_k04_listCalendarsBeforeInitializeThrows() async throws {
        let harness = Harness()
        // Правка возврата РП п. 7: право зафиксировано на .granted ДО вызова — реализация,
        // пропускающая проверку порядка, попала бы в путь К21 и замаскировала бы дефект тем же
        // зелёным цветом; счётчик Ш1 ловит его отдельно от типа ошибки.
        harness.permissions.setStatus(.granted, for: .calendars)

        do {
            _ = try await harness.connector.listCalendars()
            XCTFail("ожидался protocolViolation")
        } catch ConnectorError.protocolViolation(_) {}
        XCTAssertEqual(harness.gateway.calendarsCallCount, 0, "listCalendars до initialize не должен трогать шов")
    }
}
