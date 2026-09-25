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

    /// К9, вторая часть возврата (MEE-386, «Оставшиеся К»): таймаут НЕ расходует счётчик
    /// повтора §5.2. Верно структурно — `raceTimeout` бросает `CalendarError.timeout`, не
    /// `ConnectorError`, и `catch let error as ConnectorError` внутри `callConnector`
    /// (`CalendarPortImplCallWrapper.swift`) его не ловит вовсе, так что `attempt += 1` для
    /// таймаута физически недостижимо, — но наблюдаемого теста на это не было. Здесь: первая
    /// физическая попытка (id=2) получает `-32003` (обычный повтор, `attempt` становится 1),
    /// ВТОРАЯ (id=3) виснет и проигрывает гонку СВОЕМУ таймауту `.other` (30с) — итоговая
    /// ошибка снаружи ровно `.timeout`, а не «повторы исчерпаны» (`.transport`, тот путь,
    /// которым уходит четвёртая подряд `-32003` — `test_k56_exhaustionAfterThreeRetries...`,
    /// `StdioProtocolTests+Retries.swift`) — таймаут обрывает цикл повтора целиком, а не
    /// встраивается в его подсчёт.
    func test_k09_secondVector_timeoutDuringRetryLoopSurfacesAsTimeoutNotAsRetryExhaustion() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        let ids = StdioProtocolTests.IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        transport.hangOnNextReceive()

        async let outcome: (error: CalendarError?, sentAtThrow: [String]) = {
            do {
                _ = try await hub.listCalendars(source: StdioHarness.source)
                return (nil, transport.sent)
            } catch {
                return (error as? CalendarError, transport.sent)
            }
        }()

        // Первая физическая попытка получает -32003 — обычная задержка повтора (1с, фолбэк).
        await pollUntil { StdioProtocolTests.retryDelays(waitSeam).count == 1 }
        await pollUntil { waitSeam.resolveNext() }

        // Вторая физическая попытка виснет — гонка со СВОИМ таймаутом .other, не с повтором.
        await pollUntil { waitSeam.durations.contains(.seconds(30)) }
        await pollUntil { waitSeam.resolveNext() }

        let result = await outcome
        guard case .timeout = result.error else {
            return XCTFail("ожидался .timeout, получено \(String(describing: result.error))")
        }
        XCTAssertEqual(
            StdioProtocolTests.retryDelays(waitSeam).count, 1,
            "таймаут не добавил своей записи в задержки повтора — цикл §5.2 прерван, не продолжен"
        )
        XCTAssertEqual(
            result.sentAtThrow.count, 4,
            "initialize, listCalendars (попытка 1, -32003), listCalendars (попытка 2, виснет), shutdown"
        )
        XCTAssertTrue(result.sentAtThrow[3].contains(#""method":"shutdown""#))
    }
}
