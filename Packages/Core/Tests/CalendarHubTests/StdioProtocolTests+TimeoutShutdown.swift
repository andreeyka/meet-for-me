//  К9 вход Б (C-006 «Поведение», MEE-386) — тот же зависший вызов, что у входа А
//  (`InitializationTests.swift`), но на stdio-пути через `ScriptedRPCTransport`: после
//  истечения таймаута хост отправляет плагину кадр `shutdown`, прежде чем `CalendarError.
//  timeout` возвращается наружу вызывающей стороне. `SIGKILL` и сам факт завершения процесса
//  остаются исключением вне зоны (реального процесса здесь нет) — отправка кадра `shutdown`
//  от факта смерти процесса не зависит и наблюдаема без него.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class StdioProtocolTimeoutShutdownTests: XCTestCase {

    /// `listCalendars` — таймаут `.other` (30с, `CalendarPortImplCallWrapper.MethodTimeout`).
    /// `hangOnNextReceive()` делает `awaitResponse(id: 2)` внутри `StdioCalendarConnector`
    /// висящим НАВСЕГДА — тот же класс сценария, что «Fake…настроен никогда не возвращаться»
    /// у входа А, только на stdio-пути. `pollUntil` на `durations.contains(.seconds(30))` —
    /// та же гарантия, что и у остальных файлов пакета: `resolveNext()` не отпустит чужое ещё
    /// не вставшее ожидание того же шва.
    func test_k9_inputB_timeoutSendsShutdownFrameBeforeSurfacingTimeoutError() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.hangOnNextReceive()

        // Не типизированный `catch let error as CalendarError` — тот не исчерпывающий (любой
        // ДРУГОЙ тип ошибки ушёл бы дальше, и компилятор считает всё замыкание бросающим,
        // требуя `try` на каждом чтении `async let` ниже, хотя оно логически не бросает).
        //
        // Возврат РП (MEE-386, комментарий 09:15): `transport.sent` читается ЗДЕСЬ, внутри
        // `catch`, в момент фактической поимки ошибки — не снаружи `async let` уже ПОСЛЕ
        // того, как обе стороны (тест и вызов) синхронизировались через `await outcome`.
        // Читать снаружи технически даёт то же значение сегодня (`shutdown()` — `await`, не
        // `Task.detached`, поэтому кадр уже ушёл к моменту throw), но привязывает проверку к
        // фактическому моменту throw, а не к случайно совпадающему более позднему состоянию.
        async let outcome: (error: CalendarError?, sentAtThrow: [String]) = {
            do {
                _ = try await hub.listCalendars(source: StdioHarness.source)
                return (nil, transport.sent)
            } catch {
                return (error as? CalendarError, transport.sent)
            }
        }()

        await pollUntil { waitSeam.durations.contains(.seconds(30)) }
        await pollUntil { waitSeam.resolveNext() }

        let result = await outcome
        guard case .timeout = result.error else {
            return XCTFail("ожидался .timeout, получено \(String(describing: result.error))")
        }

        XCTAssertEqual(
            result.sentAtThrow.count, 3, "initialize, listCalendars, shutdown — по одному разу каждый"
        )
        XCTAssertTrue(result.sentAtThrow[1].contains(#""method":"listCalendars""#))
        XCTAssertTrue(
            result.sentAtThrow[2].contains(#""method":"shutdown""#),
            "shutdown ушёл ДО того, как .timeout вернулся вызывающей стороне"
        )
    }
}
