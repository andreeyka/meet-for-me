//  Группа А (К1-К10) плана MEE-361: порядок вызовов, initialize-once, источники/календари,
//  таймауты, переподключение после upstreamUnavailable (развилка Р10).
//
//  ЧТО ЭТА ПРАВКА НЕ ПОКРЫВАЕТ ЗДЕСЬ, ЧЕСТНО:
//  * К1 — только вектор порядка («ничего не вызывается раньше initialize»). Вектор с
//    MAJOR-версией `protocolVersion` нужен `ScriptedRPCTransport` (stdio, группа Ж, ещё не
//    написана) — `FakeCalendarConnector` не проходит через кадры протокола вовсе.
//  * К3, К8 — целиком: MEE-355 слилась в main уже в ходе этой правки, и оба метода
//    (`beginAuth`/`completeAuth` для К3, `configure`/`stop` для К8) в `CalendarPortImpl`
//    теперь реализованы (см. `CalendarPortImpl.swift`, раздел «Управляющая поверхность
//    источника») — но без собственных тестов здесь. Покрытие К3, К8 и всей группы Л
//    (К66-К69, К71-К75) — следующая часть той же задачи, не этот файл (файл этой группы по
//    плану MEE-361 — не `InitializationTests.swift`).
//  * К9 — только вход А (таймаут через зависший вызов). Вход Б (кадр `shutdown` на
//    stdio-пути) — группа Ж.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import CalendarHub

final class InitializationTests: XCTestCase {

    private let source = CalendarSourceId(rawValue: "src-1")

    // MARK: - К1 (вход «порядок», без MAJOR-вектора)

    func test_k01_hostNeverCallsConnectorBeforeInitialize() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setListCalendars([ConnectorCalendar(calendarId: "cal-1", title: "Cal", isReadOnly: false)])

        _ = try await harness.hub.listCalendars(source: source)

        XCTAssertEqual(connector.callCount(.initialize), 1)
        XCTAssertTrue(connector.callLog.happened(
            "CalendarConnector.initialize", before: "CalendarConnector.listCalendars"
        ))
    }

    // MARK: - К2 (оба входа)

    func test_k02_deltaSyncFalseNeverCallsFetchChanges() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1", cursor: "stale-cursor-ignored")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchEvents([])

        _ = await harness.hub.sync(trigger: .manual)

        XCTAssertEqual(connector.callCount(.fetchChanges), 0)
        XCTAssertEqual(connector.callCount(.fetchEvents), 1)
    }

    func test_k02_deltaSyncTrueWithCursorCallsFetchChangesNotFetchEvents() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1", cursor: "cursor-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: true, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchChanges(ChangeBatch(
            events: [], deletedExternalIds: [], cursor: "cursor-2", resetRequired: false
        ))

        _ = await harness.hub.sync(trigger: .manual)

        XCTAssertEqual(connector.callCount(.fetchChanges), 1)
        XCTAssertEqual(connector.callCount(.fetchEvents), 0)
    }

    // MARK: - К4

    func test_k04_listSourcesMirrorsConnectorRepositoryOrder() async {
        let harness = Harness(sourceIds: ["src-1", "src-2"])
        harness.connectorRepository.seed([Harness.record(id: "src-1"), Harness.record(id: "src-2")])

        let sources = await harness.hub.listSources()

        XCTAssertEqual(sources, [CalendarSourceId(rawValue: "src-1"), CalendarSourceId(rawValue: "src-2")])
    }

    // MARK: - К5

    func test_k05_listCalendarsMarksSelected() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1", selectedCalendarIds: ["cal-1", "cal-3"])])
        let connector = harness.connector("src-1")
        connector.setListCalendars([
            ConnectorCalendar(calendarId: "cal-1", title: "One", isReadOnly: false),
            ConnectorCalendar(calendarId: "cal-2", title: "Two", isReadOnly: false),
            ConnectorCalendar(calendarId: "cal-3", title: "Three", isReadOnly: true)
        ])

        let infos = try await harness.hub.listCalendars(source: source)

        XCTAssertEqual(infos.count, 3)
        XCTAssertEqual(infos.filter(\.isSelected).map(\.calendarId).sorted(), ["cal-1", "cal-3"])
        XCTAssertEqual(infos.first { $0.calendarId == "cal-2" }?.isSelected, false)
    }

    // MARK: - К6

    func test_k06_setSelectedCalendarsUpsertsWithoutTouchingConnector() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1", selectedCalendarIds: ["cal-1"])])
        let connector = harness.connector("src-1")

        try await harness.hub.setSelectedCalendars(source: source, calendarIds: ["cal-2", "cal-3"])

        XCTAssertEqual(harness.connectorRepository.storedRecords.first?.selectedCalendarIds, ["cal-2", "cal-3"])
        XCTAssertTrue(connector.callLog.calls.isEmpty)
    }

    // MARK: - К7

    func test_k07_initializeCalledExactlyOnce() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchEvents([])
        connector.setListCalendars([])

        _ = try await harness.hub.listCalendars(source: source)
        _ = await harness.hub.sync(trigger: .manual)
        _ = try await harness.hub.listCalendars(source: source)

        XCTAssertEqual(connector.callCount(.initialize), 1)
    }

    // MARK: - К9, вход А (границы 10/120/30с)

    func test_k09_timeoutAtInitializeTenSecondBoundary() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.hang(.initialize)

        do {
            _ = try await harness.hub.listCalendars(source: source)
            XCTFail("ожидался CalendarError.timeout")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .timeout(sourceId: source, seconds: 10))
        }
        XCTAssertTrue(harness.waitSeam.durations.contains(.seconds(10)))
    }

    func test_k09_timeoutAtFetchWindowHundredTwentySecondBoundary() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.hang(.fetchEvents)

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertEqual(results.first?.failure, .timeout(sourceId: source, seconds: 120))
        XCTAssertTrue(harness.waitSeam.durations.contains(.seconds(120)))
    }

    func test_k09_timeoutAtOtherMethodThirtySecondBoundary() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.hang(.listCalendars)

        do {
            _ = try await harness.hub.listCalendars(source: source)
            XCTFail("ожидался CalendarError.timeout")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .timeout(sourceId: source, seconds: 30))
        }
        XCTAssertTrue(harness.waitSeam.durations.contains(.seconds(30)))
    }

    // MARK: - К10 (развилка Р10)

    func test_k10_upstreamUnavailableReinitializesBeforeNextFetch() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.fail(.fetchEvents, with: .upstreamUnavailable(message: "down"))

        let firstResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNotNil(firstResults.first?.failure)
        XCTAssertEqual(connector.callCount(.initialize), 1)
        XCTAssertEqual(connector.callCount(.fetchEvents), 1)

        connector.clearFailure(.fetchEvents)
        connector.setFetchEvents([])
        let secondResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(secondResults.first?.failure)

        XCTAssertEqual(connector.callCount(.initialize), 2)
        XCTAssertEqual(connector.callCount(.fetchEvents), 2)
        let lastInit = connector.callLog.lastIndex(of: "CalendarConnector.initialize")
        let lastFetch = connector.callLog.lastIndex(of: "CalendarConnector.fetchEvents")
        XCTAssertNotNil(lastInit)
        XCTAssertNotNil(lastFetch)
        if let lastInit, let lastFetch {
            XCTAssertLessThan(lastInit, lastFetch)
        }
    }
}
