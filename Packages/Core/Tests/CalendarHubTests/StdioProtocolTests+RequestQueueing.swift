//  К12 (C-006 «Поведение», MEE-386) — не более одного `request`-кадра хоста на соединении в
//  очереди без ответа: второй вызов держится, пока первый не завершится (ответом или отменой),
//  прежде чем отправляет СВОЙ кадр. `resolvePendingHang(with:)` (`ScriptedRPCTransport.swift`)
//  отпускает первый вызов настоящим ответом, не отменой — иначе не отличить «второй ждёт слот»
//  от «второго вообще не было».
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class StdioProtocolRequestQueueingTests: XCTestCase {

    /// `pollUntil` на `connector.pendingCallSlotWaiterCount > 0` вместо сна по часам
    /// (`TestSupport.swift`'s общий приём для этого пакета) — доказывает, что второй вызов уже
    /// СТУЧИТСЯ в слот, не отправив свой кадр, без гонки «а вдруг он просто ещё не начался».
    func test_k12_hostNeverSendsSecondRequestWhileFirstIsUnanswered() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let connector = bundle.connector
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.hangOnNextReceive()

        async let first = hub.listCalendars(source: StdioHarness.source)
        await pollUntil { transport.sent.count == 2 }

        async let second = hub.listCalendars(source: StdioHarness.source)
        await pollUntil { await connector.pendingCallSlotWaiterCount > 0 }

        XCTAssertEqual(
            transport.sent.count, 2, "второй request не уходит, пока первый ещё без ответа"
        )

        transport.enqueue(#"{"schemaVersion":1,"id":3,"result":{"calendars":[]}}"#)
        transport.resolvePendingHang(with: #"{"schemaVersion":1,"id":2,"result":{"calendars":[]}}"#)

        let firstResult = try await first
        let secondResult = try await second

        XCTAssertEqual(firstResult, [])
        XCTAssertEqual(secondResult, [])
        XCTAssertEqual(transport.sent.count, 3, "initialize + listCalendars×2, по порядку, не одновременно")
        XCTAssertTrue(transport.sent[2].contains(#""method":"listCalendars""#))
    }
}
