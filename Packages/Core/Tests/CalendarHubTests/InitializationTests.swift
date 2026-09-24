//  Группа А (К1-К10) плана MEE-361: порядок вызовов, initialize-once, источники/календари,
//  таймауты, переподключение после upstreamUnavailable (развилка Р10).
//
//  ЧТО ЭТА ПРАВКА НЕ ПОКРЫВАЕТ ЗДЕСЬ, ЧЕСТНО:
//  * К1 — только вектор порядка («ничего не вызывается раньше initialize»). Вектор с
//    MAJOR-версией `protocolVersion` нужен `ScriptedRPCTransport` (stdio, группа Ж, ещё не
//    написана) — `FakeCalendarConnector` не проходит через кадры протокола вовсе.
//  * К9 — только вход А (таймаут через зависший вызов). Вход Б (кадр `shutdown` на
//    stdio-пути) — группа Ж.
//
//  MEE-362, часть 2 (эта правка): добавлены К3, К8 — оба метода (`beginAuth`/`completeAuth`
//  для К3, порядок вызовов для К8) в `CalendarPortImpl` реализованы MEE-355/частью 1, тесты
//  на них не были написаны. Группа Л (К66-К69, К71-К75) — отдельные файлы
//  `ControlSurfaceEntryPointsTests.swift`/`SourceRoutingTests.swift`, эта же правка.

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

    /// `FakeWaitSeam.sleep(for:)` не авторазрешается по умолчанию (см. TestSupport.swift) —
    /// отпускаем ворота гонки `raceTimeout` только ПОСЛЕ того, как проверяемый метод реально
    /// встал в `hangOrGate` (`callCount(method) > 0`, пишется ДО входа туда), иначе можно было
    /// бы по ошибке отпустить ворота более ранней, ещё не зависшей гонки того же шва
    /// (например, `initialize` — раньше проверяемого «остального» метода).
    /// Возвращает саму задачу (возврат РП, приёмка #94, п. 5): раньше была fire-and-forget —
    /// `XCTFail` внутри `pollUntil` (дефект 7, приёмка #85), случись он, мог не попасть в отчёт
    /// теста, если тестовый метод завершался раньше, чем отработает этот `Task`. Задача
    /// по-прежнему стартует и бежит конкурентно с проверяемым вызовом (дожидаться её тут же —
    /// взаимная блокировка: `callCount(method) > 0` станет истиной только когда проверяемый
    /// вызов реально дойдёт до зависания) — вызывающая сторона ждёт `.value` уже ПОСЛЕ
    /// проверяемого вызова, чтобы гарантировать наблюдаемость возможного `XCTFail`.
    private func resolveTimeoutAfterHang(
        _ waitSeam: FakeWaitSeam, connector: FakeCalendarConnector, method: CalendarConnectorMethod
    ) -> Task<Void, Never> {
        Task {
            // Возврат РП (приёмка #85, дефект 7): `pollUntil` ограничен по времени — раньше
            // эти два цикла висели без предела, если условие никогда не становилось истинным.
            await pollUntil { connector.callCount(method) > 0 }
            await pollUntil { waitSeam.resolveNext() }
        }
    }

    func test_k09_timeoutAtInitializeTenSecondBoundary() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.hang(.initialize)
        let watchdog = resolveTimeoutAfterHang(harness.waitSeam, connector: connector, method: .initialize)

        do {
            _ = try await harness.hub.listCalendars(source: source)
            XCTFail("ожидался CalendarError.timeout")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .timeout(sourceId: source, seconds: 10))
        }
        XCTAssertTrue(harness.waitSeam.durations.contains(.seconds(10)))
        await watchdog.value
    }

    func test_k09_timeoutAtFetchWindowHundredTwentySecondBoundary() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.hang(.fetchEvents)
        let watchdog = resolveTimeoutAfterHang(harness.waitSeam, connector: connector, method: .fetchEvents)

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertEqual(results.first?.failure, .timeout(sourceId: source, seconds: 120))
        XCTAssertTrue(harness.waitSeam.durations.contains(.seconds(120)))
        await watchdog.value
    }

    func test_k09_timeoutAtOtherMethodThirtySecondBoundary() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.hang(.listCalendars)
        let watchdog = resolveTimeoutAfterHang(harness.waitSeam, connector: connector, method: .listCalendars)

        do {
            _ = try await harness.hub.listCalendars(source: source)
            XCTFail("ожидался CalendarError.timeout")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .timeout(sourceId: source, seconds: 30))
        }
        XCTAssertTrue(harness.waitSeam.durations.contains(.seconds(30)))
        await watchdog.value
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

    // MARK: - К3 (вход А/Б)

    func test_k03_authNoneSkipsBeginAuth_oauthProxies1to1() async throws {
        let noAuthSource = CalendarSourceId(rawValue: "src-none")
        let oauthSource = CalendarSourceId(rawValue: "src-oauth")
        let harness = Harness(sourceIds: ["src-none", "src-oauth"])
        harness.connectorRepository.seed([Harness.record(id: "src-none"), Harness.record(id: "src-oauth")])
        let noAuthConnector = harness.connector("src-none")
        noAuthConnector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        let oauthConnector = harness.connector("src-oauth")
        oauthConnector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .oauth
        ))

        // Вход А: auth == .none — connector.beginAuth/completeAuth не вызываются вовсе,
        // CalendarPort.beginAuth(source:) даёт notConfigured до коннектора (тот же кейс, К74).
        do {
            _ = try await harness.hub.beginAuth(source: noAuthSource)
            XCTFail("ожидался CalendarError.notConfigured")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .notConfigured(sourceId: noAuthSource))
        }
        do {
            _ = try await harness.hub.completeAuth(source: noAuthSource, callbackUrl: URL(string: "app://cb")!)
            XCTFail("ожидался CalendarError.notConfigured")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .notConfigured(sourceId: noAuthSource))
        }
        XCTAssertEqual(noAuthConnector.callCount(.beginAuth), 0)
        XCTAssertEqual(noAuthConnector.callCount(.completeAuth), 0)

        // Вход Б: auth == .oauth — 1:1 проброс, результат как есть, без интерпретации.
        let challenge = try await harness.hub.beginAuth(source: oauthSource)
        XCTAssertEqual(oauthConnector.callCount(.beginAuth), 1)
        XCTAssertEqual(challenge, AuthChallenge(authUrl: URL(string: "https://example.com")!, redirectScheme: "app"))

        let label = try await harness.hub.completeAuth(source: oauthSource, callbackUrl: URL(string: "app://cb")!)
        XCTAssertEqual(oauthConnector.callCount(.completeAuth), 1)
        XCTAssertNil(label)
    }

    // MARK: - К8 (порядок вызовов целиком)

    /// «До initialize» — тот же вектор, что К1 (`test_k01_...`), не повторяется здесь
    /// отдельным прогоном. Этот тест — два новых угла: чередование ВНУТРИ второй фазы
    /// (`configure` после `fetchEvents`, затем снова `fetchEvents` — не нарушение) и «после
    /// shutdown» — тот же наблюдаемый факт, что К75 (`stop()` лениво переподключает, не
    /// продолжает старую сессию без нового `initialize`): здесь проверяется порядком вызовов
    /// (`initialize` СНОВА, ДО следующего метода), не отдельным «запретом», которого у
    /// in-process коннектора и нечем было бы наблюдать (кадры протокола — только у stdio).
    func test_k08_orderAllowsInterleavingButNotBeforeInitOrAfterShutdown() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.setFetchEvents([])

        // fetchEvents → configure → fetchEvents: чередование внутри второй фазы — не нарушение.
        _ = await harness.hub.sync(trigger: .manual)
        try await harness.hub.configure(source: source, settings: Data("{}".utf8))
        _ = await harness.hub.sync(trigger: .manual)

        XCTAssertEqual(connector.callCount(.fetchEvents), 2)
        XCTAssertEqual(connector.callCount(.configure), 1)
        XCTAssertEqual(connector.callCount(.initialize), 1, "initialize — один раз на источник, не на цикл")

        // После stop(): следующий вызов не продолжает старую сессию — снова initialize,
        // ПРЕЖДЕ следующего метода (тот же факт, что К75).
        await harness.hub.stop()
        _ = try await harness.hub.healthCheck(source: source)

        XCTAssertEqual(connector.callCount(.initialize), 2)
        let lastInit = connector.callLog.lastIndex(of: "CalendarConnector.initialize")
        let healthCheckIndex = connector.callLog.lastIndex(of: "CalendarConnector.healthCheck")
        XCTAssertNotNil(lastInit)
        XCTAssertNotNil(healthCheckIndex)
        if let lastInit, let healthCheckIndex {
            XCTAssertLessThan(lastInit, healthCheckIndex)
        }
    }
}
