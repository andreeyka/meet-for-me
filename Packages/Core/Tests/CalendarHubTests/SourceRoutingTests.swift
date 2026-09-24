//  Группа Л (К73-К75) плана MEE-361: управляющая поверхность источника — маршрутизация по
//  CalendarSourceId, notConfigured до коннектора, идемпотентность/ожидание/переподключение stop().

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import CalendarHub

final class SourceRoutingTests: XCTestCase {

    private let source = CalendarSourceId(rawValue: "src-1")

    // MARK: - К73 (маршрутизация по CalendarSourceId, не по порядку регистрации)

    func test_k73_routingBySourceIdNotByRegistrationOrder() async throws {
        HangDiagnostics.checkpoint("SourceRoutingTests.test_k73_routingBySourceIdNotByRegistrationOrder START")
        let ids = ["eventkit-1", "graph-work-1"]
        let harness = Harness(sourceIds: ids)
        harness.connectorRepository.seed(ids.map { Harness.record(id: $0) })
        let connectors = ids.map { harness.connector($0) }
        for connector in connectors {
            connector.setInitializeResult(capabilities: ConnectorCapabilities(
                deltaSync: false, push: false, attendees: true, conference: true, auth: .oauth
            ))
        }
        let first = connectors[0]
        let second = connectors[1]
        let target = CalendarSourceId(rawValue: "graph-work-1")

        // Тот же вектор на каждом из пяти адресующих методов — второй источник вызывается,
        // первый не тронут ни разу ни на одном из них.
        _ = try await harness.hub.beginAuth(source: target)
        XCTAssertEqual(second.callCount(.beginAuth), 1)
        XCTAssertEqual(first.callCount(.beginAuth), 0)

        _ = try await harness.hub.completeAuth(source: target, callbackUrl: URL(string: "app://cb")!)
        XCTAssertEqual(second.callCount(.completeAuth), 1)
        XCTAssertEqual(first.callCount(.completeAuth), 0)

        _ = try await harness.hub.settingsSchema(source: target)
        XCTAssertEqual(second.callCount(.settingsSchema), 1)
        XCTAssertEqual(first.callCount(.settingsSchema), 0)

        try await harness.hub.configure(source: target, settings: Data())
        XCTAssertEqual(second.callCount(.configure), 1)
        XCTAssertEqual(first.callCount(.configure), 0)

        _ = try await harness.hub.healthCheck(source: target)
        XCTAssertEqual(second.callCount(.healthCheck), 1)
        XCTAssertEqual(first.callCount(.healthCheck), 0)
    }

    // MARK: - К74 (неизвестный sourceId / auth == .none — notConfigured до коннектора)

    func test_k74_unknownSourceOrNoOAuthGivesNotConfiguredBeforeConnector() async throws {
        HangDiagnostics.checkpoint("SourceRoutingTests.test_k74_unknownSourceOrNoOAuthGivesNotConfiguredBeforeConnector START")
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        let unknown = CalendarSourceId(rawValue: "unknown")

        // Вход А: sourceId не в listSources() — notConfigured без обращения ни к одному
        // фейку, на каждом из пяти адресующих методов.
        await assertNotConfigured(unknown) { _ = try await harness.hub.beginAuth(source: unknown) }
        await assertNotConfigured(unknown) {
            _ = try await harness.hub.completeAuth(source: unknown, callbackUrl: URL(string: "app://cb")!)
        }
        await assertNotConfigured(unknown) { _ = try await harness.hub.settingsSchema(source: unknown) }
        await assertNotConfigured(unknown) { try await harness.hub.configure(source: unknown, settings: Data()) }
        await assertNotConfigured(unknown) { _ = try await harness.hub.healthCheck(source: unknown) }
        XCTAssertTrue(connector.callLog.calls.isEmpty, "зарегистрированный источник не тронут вызовами на неизвестный")

        // Вход Б: auth == .none у ЗАРЕГИСТРИРОВАННОГО источника, beginAuth — тот же самый
        // кейс CalendarError, не отдельный (К3 вход А проверяет то же поведение; здесь
        // важно, что значение буквально совпадает с ошибкой неизвестного источника).
        do {
            _ = try await harness.hub.beginAuth(source: source)
            XCTFail("ожидался CalendarError.notConfigured")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .notConfigured(sourceId: source))
        }
    }

    // MARK: - К75 (stop() — идемпотентность, ожидание всех, ленивое переподключение после)

    func test_k75_stopIdempotentAwaitsAllLazyReconnectAfter() async throws {
        HangDiagnostics.checkpoint("SourceRoutingTests.test_k75_stopIdempotentAwaitsAllLazyReconnectAfter START")
        let ids = ["src-1", "src-2", "src-3"]
        let harness = Harness(sourceIds: ids)
        harness.connectorRepository.seed(ids.map { Harness.record(id: $0) })
        let connectors = ids.map { harness.connector($0) }
        for (index, connector) in connectors.enumerated() {
            connector.setInitializeResult(capabilities: ConnectorCapabilities(
                deltaSync: false, push: false, attendees: true, conference: true, auth: .none
            ))
            connector.setListCalendars([])
            _ = try await harness.hub.listCalendars(source: CalendarSourceId(rawValue: ids[index]))
        }

        // Вход Б (ожидание всех): один источник задержан управляемо — stop() не возвращается
        // раньше, чем отработали все три.
        let delayed = connectors[2]
        delayed.hang(.shutdown)
        let flag = DoneFlag()
        let firstStop = Task {
            await harness.hub.stop()
            await flag.markDone()
        }
        // НАЙДЕНО (бисекция CI-зависания, MEE-362 ч.2, тот же приём, что у К66 —
        // `ControlSurfaceEntryPointsTests.swift` — там же и полный довод): без условия на
        // `delayed.callCount(.shutdown) > 0` `release(.shutdown)` ниже мог уйти ДО того, как
        // третий вызов вообще встал в очередь на `hangOrGate` — no-op, снимать позже уже
        // некому.
        await pollUntil {
            connectors[0].shutdownCallCount > 0 && connectors[1].shutdownCallCount > 0
                && delayed.callCount(.shutdown) > 0
        }
        let doneEarly = await flag.isDone()
        XCTAssertFalse(doneEarly, "stop() не возвращается, пока висит задержанный источник")
        delayed.release(.shutdown)
        await firstStop.value
        for connector in connectors { XCTAssertEqual(connector.shutdownCallCount, 1) }

        // Вход А (идемпотентность): второй stop() подряд фанает в пустое множество источников.
        await harness.hub.stop()
        for connector in connectors {
            XCTAssertEqual(connector.shutdownCallCount, 1, "второй stop() не задваивает fan-out")
        }

        // Вход В (ленивое переподключение): healthCheck на остановленном источнике поднимает
        // соединение заново тем же путём, что после upstreamUnavailable (К10/Р10) —
        // calendar-hub не различает «остановлен явно» и «упал».
        let target = connectors[0]
        XCTAssertEqual(target.callCount(.initialize), 1)
        _ = try await harness.hub.healthCheck(source: CalendarSourceId(rawValue: "src-1"))
        XCTAssertEqual(target.callCount(.initialize), 2)
        XCTAssertEqual(target.callCount(.healthCheck), 1)
    }

    // MARK: - Оснастка

    private func assertNotConfigured(
        _ source: CalendarSourceId, _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("ожидался CalendarError.notConfigured для \(source.rawValue)")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .notConfigured(sourceId: source))
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
    }
}
