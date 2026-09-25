//  StdioProtocolTests — К54 (§5.1, таблица кодов JSON-RPC → ConnectorError → CalendarError) и
//  К55 (инв. 19, протухший курсор). Отдельный файл — тот же приём file_length/type_body_length,
//  что у соседних расширений этого же типа.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
@testable import CalendarHub

extension StdioProtocolTests {

    // MARK: - К54 (§5.1 — таблица отображения кодов, векторы с собственным кодом)

    struct ErrorMappingVector {
        let name: String
        let code: Int
        let message: String
        let data: String?
        let expected: CalendarError
    }

    static let errorMappingVectors: [ErrorMappingVector] = [
        .init(name: "-32700 parse error", code: -32700, message: "bad json", data: nil,
              expected: .protocolViolation(sourceId: StdioHarness.source, message: "bad json")),
        .init(name: "-32600 invalid request", code: -32600, message: "bad request", data: nil,
              expected: .protocolViolation(sourceId: StdioHarness.source, message: "bad request")),
        .init(name: "-32601 method not found", code: -32601, message: "no method", data: nil,
              expected: .protocolViolation(sourceId: StdioHarness.source, message: "no method")),
        .init(name: "-32602 invalid params", code: -32602, message: "bad params", data: nil,
              expected: .protocolViolation(sourceId: StdioHarness.source, message: "bad params")),
        .init(name: "-32603 internal error", code: -32603, message: "boom", data: nil,
              expected: .transport(sourceId: StdioHarness.source, message: "boom")),
        .init(name: "-32001 authorizationRequired", code: -32001, message: "need auth", data: nil,
              expected: .authorizationRequired(sourceId: StdioHarness.source)),
        .init(name: "-32002 notConfigured", code: -32002, message: "not configured", data: nil,
              expected: .notConfigured(sourceId: StdioHarness.source)),
        .init(name: "-32005 upstreamUnavailable", code: -32005, message: "down", data: nil,
              expected: .transport(sourceId: StdioHarness.source, message: "down")),
        .init(name: "-32006 protocolViolation", code: -32006, message: "violated", data: nil,
              expected: .protocolViolation(sourceId: StdioHarness.source, message: "violated")),
        .init(name: "прочий код -32000...-32099", code: -32050, message: "weird", data: nil,
              expected: .transport(sourceId: StdioHarness.source, message: "нераспознанный код -32050: weird")),
        .init(name: "код вне всех диапазонов", code: -1, message: "n/a", data: nil,
              expected: .protocolViolation(sourceId: StdioHarness.source, message: "код вне диапазона: -1"))
    ]

    func test_k54_errorMappingTableCodeDrivenRowsPlusSourceId() async throws {
        for vector in Self.errorMappingVectors {
            let bundle = StdioHarness.make()
            let hub = bundle.hub
            let transport = bundle.transport
            transport.enqueue(StdioHarness.initializeFrame(id: 1))
            transport.enqueue(StdioHarness.errorFrame(id: 2, code: vector.code, message: vector.message))

            do {
                _ = try await hub.listCalendars(source: StdioHarness.source)
                XCTFail("\(vector.name): ожидалась ошибка")
            } catch let error as CalendarError {
                XCTAssertEqual(error, vector.expected, vector.name)
                XCTAssertEqual(error.sourceIdForTesting, StdioHarness.source, "\(vector.name): sourceId")
            }
        }
    }

    // MARK: - К55 (инв. 19 — протухший курсор)

    func test_k55_cursorInvalidForgetsCursorThenFetchesFullWindowOnce() async throws {
        let bundle = StdioHarness.make(deltaSync: true, cursor: "old-cursor")
        let hub = bundle.hub
        let transport = bundle.transport
        let connectorRepository = bundle.connectorRepository
        transport.enqueue(StdioHarness.initializeFrame(id: 1, deltaSync: true))
        transport.enqueue(StdioHarness.errorFrame(id: 2, code: -32004, message: "cursor invalid"))
        transport.enqueue(#"{"schemaVersion":1,"id":3,"result":{"events":[]}}"#)

        let results = await hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure, "инв. 19 — протухший курсор не выходит наружу")
        XCTAssertNil(connectorRepository.storedRecords.first?.cursor, "курсор забыт")
        XCTAssertEqual(transport.sent.count, 3, "initialize, fetchChanges, fetchEvents (полное окно) — по одному разу")

        // Возврат РП (приёмка #135, п. 3), хвост: следующая синхронизация начинается с
        // `fetchChanges(cursor: nil)` — не запоминает полное окно как новый режим работы.
        // `initialize` не повторяется (capabilities уже в кэше источника), поэтому четвёртый
        // исходящий кадр — сразу `fetchChanges` этого второго цикла.
        transport.enqueue(
            #"{"schemaVersion":1,"id":4,"result":"#
                + #"{"events":[],"deletedExternalIds":[],"cursor":"c2","resetRequired":false}}"#
        )
        let secondResults = await hub.sync(trigger: .manual)

        XCTAssertNil(secondResults.first?.failure)
        XCTAssertEqual(transport.sent.count, 4)
        XCTAssertTrue(transport.sent[3].contains(#""method":"fetchChanges""#))
        // `nil` при записи опускается (C-006 §2/C-001 §0.4) — ключа "cursor" в кадре нет
        // вовсе, не `"cursor":null`; отсутствие ключа здесь и есть доказательство «начал с nil».
        XCTAssertFalse(
            transport.sent[3].contains(#""cursor":"#), "второй цикл начинается с cursor: nil (ключ опущен)"
        )
    }

    func test_k55_repeatedCursorInvalidOnRecoveryFetchEventsSurfacesAsFailure() async throws {
        let bundle = StdioHarness.make(deltaSync: true, cursor: "old-cursor")
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1, deltaSync: true))
        transport.enqueue(StdioHarness.errorFrame(id: 2, code: -32004, message: "cursor invalid"))
        // Новый вектор: резервный fetchEvents ТОЖЕ отвечает -32004 — не забытый третий повтор
        // §5.2 (тот про -32003), а `ConnectorError.protocolViolation`, выходящий наружу.
        transport.enqueue(StdioHarness.errorFrame(id: 3, code: -32004, message: "cursor invalid again"))

        let results = await hub.sync(trigger: .manual)

        guard case .protocolViolation = results.first?.failure else {
            return XCTFail(
                "повторный cursorInvalid обязан выйти наружу, получено \(String(describing: results.first?.failure))"
            )
        }
    }
}

extension CalendarError {
    /// К54: единая точка сравнения `sourceId` независимо от конкретного случая — без неё
    /// пришлось бы разбирать каждый `case` таблицы вручную только ради этого поля.
    var sourceIdForTesting: CalendarSourceId? {
        switch self {
        case .notConfigured(let sourceId), .authorizationRequired(let sourceId):
            return sourceId
        case .transport(let sourceId, _), .protocolViolation(let sourceId, _):
            return sourceId
        case .timeout(let sourceId, _):
            return sourceId
        case .cancelled:
            return nil
        }
    }
}
