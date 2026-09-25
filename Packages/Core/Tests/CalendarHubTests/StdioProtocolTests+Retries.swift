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
    /// своим `Task`: обычный плоский `try await` завис бы навсегда — задержка повтора НЕ
    /// гонится ни с чем внутри `callConnector` (в отличие от 10/120/30с таймаута
    /// `raceTimeout`, которому ЕСТЬ с кем «выиграть» — операция всегда обгоняет никогда не
    /// отпускаемый ворота-таймаут сама), а висит в `FakeWaitSeam` до явного `resolveNext()`
    /// (её докстринг, TestSupport.swift, «режим ворот»). `pollUntil { resolveNext() }` и
    /// ждёт появления нужного ожидания, и отпускает его — одним выражением, без риска отпустить
    /// раньше времени чужое (в любой момент здесь висит не больше одного вызова `sleep`: гонка
    /// таймаута снята к этому моменту предыдущим `raceTimeout`, следующая — стартует только
    /// после того, как этот отпущен).
    static func callThroughRetries<Value: Sendable>(
        _ waitSeam: FakeWaitSeam, retries: Int, _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task = Task { try await operation() }
        for _ in 0 ..< retries {
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
}
