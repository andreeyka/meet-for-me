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
        // Возврат РП (MEE-386, комментарий 09:15): проверяем сам факт, что отпускать было ЧТО —
        // `@discardableResult`, но здесь именно это и есть предмет проверки (не только то, что
        // тест НЕ падает, а что `resolvePendingHang` нашёл настоящий подвешенный `receive()`,
        // а не молча отработал вхолостую на уже пустом `pendingHang`).
        let resolved = transport.resolvePendingHang(with: #"{"schemaVersion":1,"id":2,"result":{"calendars":[]}}"#)
        XCTAssertTrue(resolved, "resolvePendingHang должен был застать настоящее зависание")

        let firstResult = try await first
        let secondResult = try await second

        XCTAssertEqual(firstResult, [])
        XCTAssertEqual(secondResult, [])
        XCTAssertEqual(transport.sent.count, 3, "initialize + listCalendars×2, по порядку, не одновременно")
        XCTAssertTrue(transport.sent[2].contains(#""method":"listCalendars""#))
    }

    /// Возврат РП (MEE-386, комментарий 09:15): вызов, стоящий в очереди на слот К12, ЕСТЬ СВОЙ
    /// таймаут (`raceTimeout`) — раньше отмена этого ожидания НЕ снимала `acquireCallSlot()`
    /// (`CheckedContinuation<Void, Never>` не отменяем), и `.timeout` доходил до вызывающей
    /// стороны только ПОСЛЕ того, как слот естественно освобождался (`withThrowingTaskGroup` не
    /// возвращается, пока не завершится КАЖДАЯ дочерняя задача) — а получив слот, отменённый
    /// вызов всё равно отправлял свой `request` (спутал бы id следующего настоящего вызова,
    /// К46). Занимает слот НАПРЯМУЮ через `bundle.connector` (в обход `hub`/`raceTimeout`) —
    /// нарочно, чтобы у занимающего слот вызова НЕ было своего конкурирующего таймаута: тогда
    /// `waitSeam.durations` несёт РОВНО одну запись (таймаут `.initialize`, 10с — `ensureInitialized`
    /// у второго вызова ещё не инициализирован), и `resolveNext()` не рискует снять чужое
    /// ожидание (та же ловушка, что уже возвращали, приёмка #128, п. 4, — здесь исключена самой
    /// конструкцией теста, не дополнительной проверкой `durations`).
    func test_k12_queuedCallTimesOutPromptlyWithoutSendingItsOwnRequest() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let connector = bundle.connector
        let waitSeam = bundle.waitSeam
        transport.hangOnNextReceive()

        async let holder: [ConnectorCalendar]? = try? await connector.listCalendars()
        await pollUntil { transport.sent.count == 1 }

        async let queued: (error: CalendarError?, sentAtThrow: [String]) = {
            do {
                _ = try await hub.listCalendars(source: StdioHarness.source)
                return (nil, transport.sent)
            } catch {
                return (error as? CalendarError, transport.sent)
            }
        }()
        await pollUntil { await connector.pendingCallSlotWaiterCount > 0 }

        await pollUntil { waitSeam.durations.contains(.seconds(10)) }
        await pollUntil { waitSeam.resolveNext() }

        let result = await queued
        guard case .timeout = result.error else {
            return XCTFail("ожидался .timeout у второго вызова, получено \(String(describing: result.error))")
        }
        XCTAssertEqual(
            result.sentAtThrow.count, 2,
            "первый кадр (listCalendars, держит слот) + shutdown безусловно на .timeout (К9 вход Б)"
        )
        XCTAssertFalse(
            result.sentAtThrow.contains { $0.contains(#""method":"initialize""#) },
            "второй вызов отменён на СВОЁМ таймауте, стоя в очереди — свой request (initialize) так и не ушёл"
        )
        XCTAssertTrue(result.sentAtThrow[1].contains(#""method":"shutdown""#))

        // `holder` не читается явно: `async let`, вышедший из области видимости непрочитанным,
        // Swift сам отменяет и ДОЖИДАЕТСЯ (структурная конкурентность) — отмена снимает зависший
        // `receive()` тем же путём, что и К9 вход Б (`.hang`-ветка теперь отвечает на отмену),
        // так что функция не виснет по возврату из теста, хотя сценарий так и не дал ответа.
    }
}
