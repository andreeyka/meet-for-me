//  К32 (развилка Р2 — окно синхронизации от текущего now, не зависит от lastSyncAt), К33
//  (sync(trigger:) — ровно один CalendarSyncResult на источник), К34 (C-005 инв. 8 — failure
//  изолирован по источнику), К36 (развилка Р7 — разные источники синхронизируются параллельно).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class SyncWindowAndFanoutTests: XCTestCase {

    /// Вход А: первая синхронизация (`lastSyncAt == nil`). Вход Б: `lastSyncAt` — месяц
    /// назад. Ответ (оба входа): `fetchEvents(from:to:)` вызывается с `from == now − 7д`,
    /// `to == now + 90д` от ТЕКУЩЕГО `now` — формула не растёт с возрастом установки и не
    /// отталкивается от `lastSyncAt`, вход А и вход Б дают одну и ту же формулу.
    func test_k32_syncWindowIsAlwaysNowMinus7DaysToNowPlus90DaysRegardlessOfLastSyncAt() async throws {
        let freshHarness = Harness(sourceIds: ["src-1"])
        freshHarness.connectorRepository.seed([Harness.record(id: "src-1", lastSyncAt: nil)])
        freshHarness.connector("src-1").setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        freshHarness.connector("src-1").setFetchEvents([])
        let beforeA = Date()
        _ = await freshHarness.hub.sync(trigger: .manual)
        try Self.assertWindowMatchesFormula(freshHarness.connector("src-1"), around: beforeA)

        let staleHarness = Harness(sourceIds: ["src-1"])
        staleHarness.connectorRepository.seed([
            Harness.record(id: "src-1", lastSyncAt: Date().addingTimeInterval(-30 * 24 * 3_600))
        ])
        staleHarness.connector("src-1").setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        staleHarness.connector("src-1").setFetchEvents([])
        let beforeB = Date()
        _ = await staleHarness.hub.sync(trigger: .manual)
        try Self.assertWindowMatchesFormula(staleHarness.connector("src-1"), around: beforeB)
    }

    private static func assertWindowMatchesFormula(
        _ connector: FakeCalendarConnector, around now: Date, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let fetchEventsCall = connector.callLog.calls(port: "CalendarConnector").last { $0.method == "fetchEvents" }
        let call = try XCTUnwrap(fetchEventsCall, file: file, line: line)
        let from = try XCTUnwrap(Double(call.arguments[0]), file: file, line: line)
        let to = try XCTUnwrap(Double(call.arguments[1]), file: file, line: line)
        XCTAssertEqual(
            from, now.addingTimeInterval(-7 * 24 * 3_600).timeIntervalSince1970, accuracy: 5,
            "окно от = now-7д", file: file, line: line
        )
        XCTAssertEqual(
            to, now.addingTimeInterval(90 * 24 * 3_600).timeIntervalSince1970, accuracy: 5,
            "окно до = now+90д", file: file, line: line
        )
    }

    /// Вход: три зарегистрированных источника. Ответ: `sync(trigger:)` возвращает ровно три
    /// `CalendarSyncResult`, по одному на источник из `listSources()`.
    func test_k33_syncReturnsExactlyOneResultPerRegisteredSource() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2", "src-3"])
        for id in ["src-1", "src-2", "src-3"] { harness.connector(id).setFetchEvents([]) }

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertEqual(results.count, 3)
        let expected = Set(["src-1", "src-2", "src-3"].map { CalendarSourceId(rawValue: $0) })
        XCTAssertEqual(Set(results.map(\.sourceId)), expected)
    }

    /// Вход: три источника; второй настроен отказывать. Ответ: `failure != nil` только у
    /// второго; первый и третий получают `failure == nil`.
    func test_k34_failureIsIsolatedToTheFailingSourceOnly() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2", "src-3"])
        harness.connector("src-1").setFetchEvents([])
        harness.connector("src-2").fail(.fetchEvents, with: .protocolViolation(message: "boom"))
        harness.connector("src-3").setFetchEvents([])

        let results = await harness.hub.sync(trigger: .manual)

        let bySource = Dictionary(uniqueKeysWithValues: results.map { ($0.sourceId.rawValue, $0) })
        XCTAssertNil(bySource["src-1"]?.failure)
        XCTAssertNotNil(bySource["src-2"]?.failure)
        XCTAssertNil(bySource["src-3"]?.failure)
    }

    /// Развилка Р7: два источника, оба с управляемой задержкой ответа. Ответ: оба вызова
    /// стартуют без ожидания друг друга — оба successfully дошли до `hangOrGate` (оба
    /// `callCount(.fetchEvents) > 0`) ПРЕЖДЕ чем тест отпустил хотя бы одни ворота, что было
    /// бы невозможно, если бы второй ждал завершения первого.
    func test_k36_differentSourcesSyncInParallelNeitherWaitsForTheOther() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        harness.connector("src-1").setFetchEvents([])
        harness.connector("src-2").setFetchEvents([])
        harness.connector("src-1").hang(.fetchEvents)
        harness.connector("src-2").hang(.fetchEvents)

        let task = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil { harness.connector("src-1").callCount(.fetchEvents) > 0 }
        await pollUntil { harness.connector("src-2").callCount(.fetchEvents) > 0 }
        harness.connector("src-1").release(.fetchEvents)
        harness.connector("src-2").release(.fetchEvents)

        let results = await task.value
        XCTAssertEqual(results.filter { $0.failure == nil }.count, 2)
    }
}
