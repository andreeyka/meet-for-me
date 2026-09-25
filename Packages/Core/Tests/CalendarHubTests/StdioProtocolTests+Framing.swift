//  StdioProtocolTests — К48-К51 (кадрирование §2/§5, полезная нагрузка §6.1, schemaVersion
//  конверта инв. 16). Расширение отдельным файлом — SwiftLint `file_length`/`type_body_length`
//  считают каждое расширение типа отдельно, не суммой по модулю (тот же приём, что уже развёл
//  CalendarPortImpl.swift на три файла).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

extension StdioProtocolTests {

    // MARK: - К48 (§2, §5 — кадрирование)

    func test_k48_inputA_frameLongerThan8MiBIsProtocolViolation() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        let huge = String(repeating: "x", count: 9 * 1024 * 1024)
        transport.enqueue(#"{"schemaVersion":1,"id":2,"result":{"calendars":[]},"huge":""# + huge + "\"}")

        await assertListCalendarsFails(hub)
    }

    func test_k48_inputB_unparsableFrameIsProtocolViolation() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue("это не json вовсе")

        await assertListCalendarsFails(hub)
    }

    func test_k48_inputC_duplicateKeyIsProtocolViolation() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"schemaVersion":1,"schemaVersion":1,"id":2,"result":{"calendars":[]}}"#)

        await assertListCalendarsFails(hub)
    }

    func test_k48_inputD_nonCanonicalDateFieldIsProtocolViolation() async throws {
        // Целочисленное поле вне канонической формы — то же самое отображение, тем же путём,
        // покрыто К51 (`schemaVersion` конверта) отдельным тестом ниже; здесь — половина
        // вектора, специфичная payload'у события (`Date`): пробел вместо `T` вне грамматики
        // §0.4 (`YYYY-MM-DDThh:mm:ss[.f{1,9}](Z|±hh:mm)`).
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(Self.fetchEventsResultFrame(id: 2, events: [
            Self.eventJSON(start: "2024-01-01 00:00:00.000Z")
        ]))

        let results = await hub.sync(trigger: .manual)
        Self.assertFailureIsProtocolViolation(results.first?.failure, "не-канонической дате")
    }

    /// Возврат РП (приёмка #135, п. 3): вторая половина входа Г — целочисленное поле вне
    /// представимости §0.2 п. 9 (±(2^53-1)). `id` ответа вне этого диапазона проваливает
    /// строгое чтение `decodeBounded` внутри `RPCFramePeek` (`try?` глушит его в `nil`), и
    /// кадр без распознанного `id` уходит тем же путём, что кадр вовсе без него (К46/К47:
    /// нет `method` — тоже отказ, не тихая трактовка как notification).
    func test_k48_inputD_integerFieldOutsideRepresentableRangeIsProtocolViolation() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"schemaVersion":1,"id":99999999999999999999,"result":{"calendars":[]}}"#)

        await assertListCalendarsFails(hub)
    }

    func assertListCalendarsFails(_ hub: CalendarPortImpl, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await hub.listCalendars(source: StdioHarness.source)
            XCTFail("ожидался protocolViolation", file: file, line: line)
        } catch let error as CalendarError {
            guard case .protocolViolation = error else {
                return XCTFail("ожидался .protocolViolation, получено \(error)", file: file, line: line)
            }
            // Возврат РП (приёмка #135, п. 3): строки §5.1 «кода нет» (кадр >8МиБ, битое
            // кадрирование, дублирующийся ключ, schemaVersion не тот) тоже несут sourceId —
            // проверено здесь одним местом, а не только у кодовых строк К54.
            XCTAssertEqual(error.sourceIdForTesting, StdioHarness.source, file: file, line: line)
        } catch {
            XCTFail("неожиданный тип ошибки: \(error)", file: file, line: line)
        }
    }

    // MARK: - К49 (инв. 10 — один негодный объект отбрасывает весь ответ)

    func test_k49_oneInvalidEventInFetchEventsResponseDiscardsWholeResponse() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        // Первое событие валидно, второе — без обязательного `sourceConnectorId`.
        transport.enqueue(Self.fetchEventsResultFrame(id: 2, events: [
            Self.eventJSON(externalId: "e1"),
            Self.eventJSON(includeSourceConnectorId: false, externalId: "e2")
        ]))

        let results = await hub.sync(trigger: .manual)
        Self.assertFailureIsProtocolViolation(results.first?.failure, "частично негодный ответ")
    }

    // MARK: - К50 (инв. 9, 13, 15 — MeetingEventPayload через провод)

    func test_k50_inputA_idKeyInPayloadIsRejectedBeforeOtherFields() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(Self.fetchEventsResultFrame(id: 2, events: [Self.eventJSON(includeId: true)]))

        let results = await hub.sync(trigger: .manual)
        Self.assertFailureIsProtocolViolation(results.first?.failure, "ключ id в payload")
    }

    func test_k50_inputB_c001InvariantViolationIsRejected() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        // `organizer.email` без `@` — нарушение C-001, не приведённое к `nil` источником.
        transport.enqueue(Self.fetchEventsResultFrame(id: 2, events: [
            Self.eventJSON(organizerJSON: #"{"email":"not-an-email","name":null}"#)
        ]))

        let results = await hub.sync(trigger: .manual)
        Self.assertFailureIsProtocolViolation(results.first?.failure, "нарушение инварианта C-001")
    }

    static func assertFailureIsProtocolViolation(
        _ failure: CalendarError?, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .protocolViolation = failure else {
            return XCTFail(
                "\(label): ожидался .protocolViolation, получено \(String(describing: failure))",
                file: file, line: line
            )
        }
        // Возврат РП (приёмка #135, п. 3): те же «строки без кода» §5.1, тем же местом —
        // fetchEvents-путь (К49/К50/К48 вход Г), не только listCalendars-путь выше.
        XCTAssertEqual(failure?.sourceIdForTesting, StdioHarness.source, file: file, line: line)
    }

    static func fetchEventsResultFrame(id: Int, events: [String]) -> String {
        #"{"schemaVersion":1,"id":\#(id),"result":{"events":[\#(events.joined(separator: ","))]}}"#
    }

    static func eventJSON(
        includeId: Bool = false,
        includeSourceConnectorId: Bool = true,
        externalId: String = "e1",
        start: String = "2024-01-01T00:00:00.000Z",
        organizerJSON: String = "null"
    ) -> String {
        let idField = includeId ? #""id":"00000000-0000-0000-0000-000000000001","# : ""
        let sourceField = includeSourceConnectorId ? #""sourceConnectorId":"src-1","# : ""
        return #"""
        {\#(idField)\#(sourceField)"externalId":"\#(externalId)","icalUid":null,"title":"t","start":"\#(start)",
         "end":"2024-01-01T01:00:00.000Z","timeZone":"UTC","isAllDay":false,"isCancelled":false,
         "organizer":\#(organizerJSON),"attendees":[],"location":null,"bodyText":null,"conference":null,
         "lastModified":"2024-01-01T00:00:00.000Z"}
        """#
    }

    // MARK: - К51 (§1.2, инв. 16 — schemaVersion конверта)

    func test_k51_schemaVersionMismatchIsProtocolViolation() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"schemaVersion":2,"id":2,"result":{"calendars":[]}}"#)

        await assertListCalendarsFails(hub)
    }

    func test_k51_schemaVersionMissingIsProtocolViolation() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"id":2,"result":{"calendars":[]}}"#)

        await assertListCalendarsFails(hub)
    }
}
