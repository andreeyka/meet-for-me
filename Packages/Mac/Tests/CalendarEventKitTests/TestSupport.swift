//  Оснастка тестов модуля `calendar-eventkit` — фейковый шов (план MEE-343 §1).
//
//  * `FakeEventKitGateway` — задаёт исход `calendars()`/`events(from:to:calendarIds:)`
//    (готовый список либо один из двух случаев `EventKitGatewayError`, Ш3), считает вызовы.
//  * `Harness` — коннектор на подставленном мире (`FakePermissionsPort`,
//    `FakeConnectorHostServices`), plus фабрики `RawEvent`/`RawCalendar`/... с умолчаниями.

import DomainCore
import DomainTestKit
import Foundation
import XCTest
@testable import CalendarEventKit

// MARK: - Шов

final class FakeEventKitGateway: EventKitGateway, @unchecked Sendable {
    private let lock = NSLock()
    private var scriptedCalendars: [RawCalendar] = []
    private var scriptedEvents: [RawEvent] = []
    private var scriptedError: EventKitGatewayError?
    private var calendarsCalls = 0
    private var eventsCalls = 0

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func setCalendars(_ calendars: [RawCalendar]) { locked { scriptedCalendars = calendars } }
    func setEvents(_ events: [RawEvent]) { locked { scriptedEvents = events } }
    func fail(with error: EventKitGatewayError) { locked { scriptedError = error } }

    var calendarsCallCount: Int { locked { calendarsCalls } }
    var eventsCallCount: Int { locked { eventsCalls } }

    func calendars() async throws -> [RawCalendar] {
        let (result, error) = locked { () -> ([RawCalendar], EventKitGatewayError?) in
            calendarsCalls += 1
            return (scriptedCalendars, scriptedError)
        }
        if let error { throw error }
        return result
    }

    func events(from: Date, to: Date, calendarIds: [String]) async throws -> [RawEvent] {
        let (result, error) = locked { () -> ([RawEvent], EventKitGatewayError?) in
            eventsCalls += 1
            return (scriptedEvents, scriptedError)
        }
        if let error { throw error }
        return result
    }
}

// MARK: - Харнесс

struct Harness {
    let gateway = FakeEventKitGateway()
    let permissions = FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date())
    let host = FakeConnectorHostServices()
    let platformResolver: PlatformResolver
    let connector: EventKitConnector

    /// - Parameter platformResolver: резолвер для К29 (IR-118, C-009 v11) — `FixedPlatformResolver`
    ///   с пустым словарём для тестов, не касающихся `conference`; возврат РП (Д12, 24.09) — тип
    ///   параметра сужен до протокола `PlatformResolver`, чтобы принимать и локальные
    ///   записывающие фейки теста (тот фиксирует не только ответ, но и `source` вызова).
    init(platformResolver: PlatformResolver = FixedPlatformResolver(answers: [:])) {
        self.platformResolver = platformResolver
        connector = EventKitConnector(gateway: gateway, permissions: permissions, platformResolver: platformResolver)
    }

    @discardableResult
    func initialize(connectorInstanceId: String = "eventkit-test") async throws -> (PluginInfo, ConnectorCapabilities) {
        try await connector.initialize(host: host, connectorInstanceId: connectorInstanceId)
    }
}

// MARK: - Фабрики сырых значений (умолчания — нейтральные, тест переопределяет нужное поле)

extension RawCalendar {
    static func fixture(
        calendarId: String = "cal-1", title: String = "Календарь", isReadOnly: Bool = false
    ) -> RawCalendar {
        RawCalendar(calendarId: calendarId, title: title, isReadOnly: isReadOnly)
    }
}

extension RawPerson {
    static func fixture(name: String? = "Тестовый Участник", email: String? = "person@example.com") -> RawPerson {
        RawPerson(name: name, email: email)
    }
}

extension RawAttendee {
    static func fixture(
        person: RawPerson = .fixture(), responseStatus: RawResponseStatus = .accepted, isOptional: Bool = false
    ) -> RawAttendee {
        RawAttendee(person: person, responseStatus: responseStatus, isOptional: isOptional)
    }
}

extension RawEvent {
    static func fixture(
        calendarId: String = "cal-1",
        externalId: String = "evt-1",
        icalUid: String? = nil,
        title: String = "Событие",
        start: Date = Date(timeIntervalSince1970: 1_700_000_000),
        end: Date = Date(timeIntervalSince1970: 1_700_003_600),
        timeZoneIdentifier: String = "UTC",
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        organizer: RawPerson? = nil,
        attendees: [RawAttendee] = [],
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil,
        lastModified: Date = Date(timeIntervalSince1970: 1_699_999_000)
    ) -> RawEvent {
        RawEvent(
            calendarId: calendarId, externalId: externalId, icalUid: icalUid, title: title,
            start: start, end: end, timeZoneIdentifier: timeZoneIdentifier, isAllDay: isAllDay,
            isCancelled: isCancelled, organizer: organizer, attendees: attendees, location: location,
            notes: notes, url: url, lastModified: lastModified
        )
    }
}
