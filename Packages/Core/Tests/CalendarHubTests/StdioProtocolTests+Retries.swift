//  StdioProtocolTests — К56 (§5.2, инв. 20: политика повторов на -32003 rateLimited).
//  Отдельный файл — тот же приём file_length/type_body_length, что у соседних расширений
//  этого же типа.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
@testable import CalendarHub

extension StdioProtocolTests {

    // MARK: - К56 (§5.2, инв. 20 — политика повторов)

    /// Каждая физическая попытка (в том числе повтор ТОЙ ЖЕ логической операции) — отдельный
    /// исходящий `request` со своим `id` (К46, «id не переиспользуется») — счётчик здесь
    /// строго повторяет `StdioCalendarConnector.nextId`, чтобы не считать вручную в каждом
    /// тесте и не разъехаться с реальной последовательностью на лишнем/забытом повторе.
    final class IdCounter {
        private var next = 1
        func advance() -> Int { defer { next += 1 }; return next }
    }

    /// Отпускает `retries` ожидаемых задержек §5.2 по одной, пока сам вызов идёт параллельно
    /// своим `Task`: обычный плоский `try await` завис бы навсегда — задержка повтора висит в
    /// `FakeWaitSeam` до явного `resolveNext()` (её докстринг, TestSupport.swift, «режим
    /// ворот»).
    ///
    /// Возврат РП (приёмка #135, п. 1): голый `pollUntil { resolveNext() }` без предварительной
    /// проверки `durations` — тот же приём, за который уже возвращали #128 (п. 4,
    /// `SyncErrorSurfaceAndScheduleTests.swift:84-93`) — `resolveNext()` берёт первую попавшуюся
    /// запись словаря `pending`, без разбора по длительности; ею мог бы оказаться ещё не
    /// снятый ворота-таймаут `raceTimeout` (10/30с), а не задержка повтора. Здесь сперва ждём,
    /// что счётчик `retryDelays` РЕАЛЬНО вырос до ожидаемого шага (задержка уже в `durations`,
    /// см. `FakeWaitSeam.sleep` — пишет ДО ожидания результата), и только потом отпускаем.
    static func callThroughRetries<Value: Sendable>(
        _ waitSeam: FakeWaitSeam, retries: Int, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task { try await operation() }
        var resolvedSoFar = 0
        while resolvedSoFar < retries {
            resolvedSoFar += 1
            let expected = resolvedSoFar
            await pollUntil { retryDelays(waitSeam).count >= expected }
            await pollUntil { waitSeam.resolveNext() }
        }
        return try await task.value
    }

    /// `waitSeam.durations` — общий журнал ЛЮБОГО `sleep(for:)`, включая гонку `raceTimeout`
    /// самого таймаута (10с `.initialize`/30с `.other`) на КАЖДОЙ попытке (записывается,
    /// когда `sleep(for:)` вызван, раньше любой отмены — тот же приём, на который опираются
    /// уже принятые тесты этого модуля, см. `InitializationTests.swift`/
    /// `ControlSurfaceEntryPointsTests.swift`, ни один из них не сравнивает `durations`
    /// целиком). Отфильтровано здесь ровно так же — оставляет только задержки повтора §5.2,
    /// которые эти тесты и проверяют.
    static func retryDelays(_ waitSeam: FakeWaitSeam) -> [Duration] {
        waitSeam.durations.filter { $0 != .seconds(10) && $0 != .seconds(30) }
    }

    func test_k56_defaultRateLimitedUsesFixedBackoff1_2_4() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await Self.callThroughRetries(waitSeam, retries: 3) {
            try await hub.listCalendars(source: StdioHarness.source)
        }

        XCTAssertEqual(Self.retryDelays(waitSeam), [.seconds(1), .seconds(2), .seconds(4)])
    }

    func test_k56_validRetryAfterSecondsUsedVerbatim() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        for _ in 0 ..< 3 {
            transport.enqueue(StdioHarness.errorFrame(
                id: ids.advance(), code: -32003, message: "slow down", data: #"{"retryAfterSeconds":5}"#
            ))
        }
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await Self.callThroughRetries(waitSeam, retries: 3) {
            try await hub.listCalendars(source: StdioHarness.source)
        }

        XCTAssertEqual(Self.retryDelays(waitSeam), [.seconds(5), .seconds(5), .seconds(5)])
    }

    func test_k56_retryAfterSecondsCeilingIsSixty() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(StdioHarness.errorFrame(
            id: ids.advance(), code: -32003, message: "slow down", data: #"{"retryAfterSeconds":3600}"#
        ))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await Self.callThroughRetries(waitSeam, retries: 1) {
            try await hub.listCalendars(source: StdioHarness.source)
        }

        XCTAssertEqual(Self.retryDelays(waitSeam), [.seconds(60)], "потолок ожидания — 60с, не 3600")
    }

    func test_k56_exhaustionAfterThreeRetriesSurfacesTransportError() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        for _ in 0 ..< 4 {
            transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        }

        do {
            _ = try await Self.callThroughRetries(waitSeam, retries: 3) {
                try await hub.listCalendars(source: StdioHarness.source)
            }
            XCTFail("четыре подряд -32003 обязаны исчерпать повторы")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .transport(sourceId: StdioHarness.source, message: "rateLimited, retryAfter=4"))
        }
        XCTAssertEqual(
            Self.retryDelays(waitSeam), [.seconds(1), .seconds(2), .seconds(4)], "ровно три задержки, не четыре"
        )
    }

    func test_k56_initializeAlsoParticipatesInRetryPolicy() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        let ids = IdCounter()
        for _ in 0 ..< 3 {
            transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        }
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        let calendars = try await Self.callThroughRetries(waitSeam, retries: 3) {
            try await hub.listCalendars(source: StdioHarness.source)
        }

        XCTAssertEqual(calendars, [])
        XCTAssertEqual(
            Self.retryDelays(waitSeam), [.seconds(1), .seconds(2), .seconds(4)], "initialize тоже повторяется"
        )
    }

    func test_k56_nonIntegerRetryAfterSecondsFallsBackToFixedDelay() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(StdioHarness.errorFrame(
            id: ids.advance(), code: -32003, message: "slow down", data: #"{"retryAfterSeconds":1.5}"#
        ))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await Self.callThroughRetries(waitSeam, retries: 1) {
            try await hub.listCalendars(source: StdioHarness.source)
        }

        XCTAssertEqual(Self.retryDelays(waitSeam), [.seconds(1)], "1.5 не целое — фолбэк, не округление")
    }

    /// Отдельно от `1.5`: `1e400` вне представимости `Double` на переполнении экспоненты — §2
    /// прямо предупреждает, что поведение разборщика Foundation здесь НЕ описано ни одним
    /// документом и вправе отличаться между Linux и Darwin (МЕЕ-361, «К56, вектор 1e400») —
    /// единственный вектор всего перечня, где кросс-платформенное тождество САМО часть
    /// критерия. Отдельный тест — если платформы разойдутся, красным станет только этот
    /// вектор, не увлекая за собой соседний `1.5` (обычное нецелое число, без такого риска).
    func test_k56_overflowRetryAfterSecondsFallsBackToFixedDelay() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(StdioHarness.errorFrame(
            id: ids.advance(), code: -32003, message: "slow down", data: #"{"retryAfterSeconds":1e400}"#
        ))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await Self.callThroughRetries(waitSeam, retries: 1) {
            try await hub.listCalendars(source: StdioHarness.source)
        }

        XCTAssertEqual(Self.retryDelays(waitSeam), [.seconds(1)])
    }

    /// Возврат РП (приёмка #135, п. 3): «shutdown никогда не повторяется» (§5.2) не была
    /// покрыта отдельным входом. `StdioCalendarConnector.shutdown()` вообще не читает ответ
    /// (некому было бы отвечать `-32003`) — доказательство «не повторяется» здесь именно в
    /// этом: `stop()` не виснет и кадр `shutdown` уходит РОВНО один раз, хотя сценарий не
    /// содержит для него вообще никакого ответа.
    func test_k56_shutdownNeverRetriesSinceItNeverAwaitsAResponse() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"schemaVersion":1,"id":2,"result":{"calendars":[]}}"#)
        _ = try await hub.listCalendars(source: StdioHarness.source)

        await hub.stop()

        XCTAssertEqual(transport.sent.count, 3, "initialize, listCalendars, shutdown — по одному разу каждый")
        XCTAssertTrue(transport.sent[2].contains(#""method":"shutdown""#), "третий кадр — shutdown")
    }

    /// Возврат РП (MEE-386): вход выше доказывает «не повторяется» СТРУКТУРНО — сценарий вовсе
    /// не содержит ответа на `shutdown`, так что повторить было бы нечего. Здесь — тот же
    /// вывод буквально: сценарий СОДЕРЖИТ настоящий кадр `-32003` (rateLimited, §5.1) на id
    /// `shutdown`-запроса, но `shutdown()` (`StdioCalendarConnector.swift`) никогда не читает
    /// ответ (`awaitResponse` не вызывается вовсе) — кадр остаётся непрочитанным в очереди
    /// сценария, а не провоцирует повтор. `transport.sent.count` не растёт после `stop()` —
    /// прямое доказательство отсутствия повторной попытки.
    func test_k56_shutdownIgnoresRateLimitedErrorFrameAndDoesNotRetry() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        let waitSeam = bundle.waitSeam
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"schemaVersion":1,"id":2,"result":{"calendars":[]}}"#)
        _ = try await hub.listCalendars(source: StdioHarness.source)

        // id=3 — то, что реально получит исходящий кадр `shutdown` (initialize=1, listCalendars=2).
        transport.enqueue(StdioHarness.errorFrame(id: 3, code: -32003, message: "slow down"))

        await hub.stop()

        XCTAssertEqual(
            transport.sent.count, 3, "shutdown ушёл ровно 1 раз — -32003 в очереди не спровоцировал повтор"
        )
        XCTAssertTrue(transport.sent[2].contains(#""method":"shutdown""#), "третий кадр — shutdown")
        XCTAssertTrue(
            Self.retryDelays(waitSeam).isEmpty, "shutdown не проходит через политику повторов §5.2 вовсе"
        )
    }
}
