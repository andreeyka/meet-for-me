//  Группа Ж плана MEE-361 (К46-К56, C-006 §2/§5/§5.1/§5.2/§7) — хост stdio через
//  `ScriptedRPCTransport`/`StdioCalendarConnector` (MEE-402 шаг 2). К57-К65 — отдельные файлы
//  (уже написаны частями 3и/3з, некоторые уже упоминают Ш2 в MEE-361 не как новый тест, а как
//  учёт: К64/К65 полностью проверены транспорт-независимой оснасткой `FakeCalendarConnector`
//  ранее и здесь не повторяются). К9 вход Б/К12/К1 (MAJOR-вектор) — тоже НЕ здесь: они
//  используют этот же `StdioCalendarConnector`, но требуют правки `CalendarPortImplCallWrapper`
//  (кадр `shutdown` на таймауте) и `HostServicesTests.swift`, которых эта задача не трогает —
//  следующая часть MEE-386 по прямому слову РП (переставлен порядок портов: сначала хост, эти
//  три — сразу за ним).
//
//  К54 в этом файле — ТОЛЬКО таблица кодов JSON-RPC → ConnectorError → CalendarError (11
//  различимых кодовых векторов из 19 строк §5.1): три строки без кода (таймаут — К9, отменённый
//  Task — общий Swift-механизм, не специфичный stdio, смерть процесса — вне зоны) и две строки
//  с кодом, но собственным тестом (-32003 — К56, -32004 — К55) сюда не входят и не
//  переиспользуются здесь — не потому, что забыты, а потому, что путь мимо кодовой таблицы
//  (framing/schemaVersion/DecodingError) уже целиком покрыт К48/К49/К50/К51 этого же файла.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

private enum StdioHarness {
    static let source = CalendarSourceId(rawValue: "src-1")

    static func make(deltaSync: Bool = false, cursor: String? = nil) -> (
        hub: CalendarPortImpl, transport: ScriptedRPCTransport,
        connectorRepository: InMemoryConnectorRepository, waitSeam: FakeWaitSeam
    ) {
        let transport = ScriptedRPCTransport()
        let connector = StdioCalendarConnector(transport: transport)
        let connectorRepository = InMemoryConnectorRepository(log: PortCallLog())
        let meetingRepository = InMemoryMeetingRepository(log: PortCallLog())
        let waitSeam = FakeWaitSeam()
        // Ни один тест этого файла не проверяет таймаут (К9, отдельная задача) — ворота Ш3
        // здесь мешали бы без цели; повтор §5.2 (К56) не гонится с другой задачей (в отличие
        // от `raceTimeout`), авторазрешение читает и хранит запрошенные `duration` как обычно.
        waitSeam.setAutoResolve(true)
        connectorRepository.seed([Harness.record(id: "src-1", cursor: cursor)])
        let hub = CalendarPortImpl(
            connectorRepository: connectorRepository, meetingRepository: meetingRepository,
            waitSeam: waitSeam, secretStore: FakeSecretStore(), connectors: [source: connector]
        )
        return (hub, transport, connectorRepository, waitSeam)
    }

    static func initializeFrame(id: Int, deltaSync: Bool = false) -> String {
        """
        {"schemaVersion":1,"id":\(id),"result":{\
        "plugin":{"id":"plug","name":"Plug","version":"1.0"},\
        "capabilities":{"deltaSync":\(deltaSync),"push":false,"attendees":true,"conference":true,"auth":"none"}}}
        """
    }

    static func errorFrame(id: Int, code: Int, message: String, data: String? = nil) -> String {
        let dataPart = data.map { ",\"data\":\($0)" } ?? ""
        return #"{"schemaVersion":1,"id":\#(id),"error":{"code":\#(code),"message":"\#(message)"\#(dataPart)}}"#
    }
}

final class StdioProtocolTests: XCTestCase {

    // MARK: - К46 (инв. 3 — запрос↔ответ по id; отдельный вход — id не переиспользуется)

    func test_k46_wrongResponseIdIsImmediateProtocolViolation_idsNeverReused() async throws {
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        // listCalendars получит id=2 — сценарий отвечает id=99, которого хост не посылал.
        transport.enqueue(#"{"schemaVersion":1,"id":99,"result":{"calendars":[]}}"#)

        do {
            _ = try await hub.listCalendars(source: StdioHarness.source)
            XCTFail("ожидался protocolViolation на чужом id")
        } catch let error as CalendarError {
            guard case .protocolViolation = error else {
                return XCTFail("ожидался .protocolViolation, получено \(error)")
            }
        }

        XCTAssertEqual(transport.sent.count, 2, "второго запроса на тот же вызов не было — отказ немедленный")
        XCTAssertTrue(transport.sent[0].contains(#""id":1"#), "initialize — id=1")
        XCTAssertTrue(transport.sent[1].contains(#""id":2"#), "listCalendars — id=2, не переиспользован")
    }

    // MARK: - К47 (инв. 4 — notification без ответа)

    func test_k47_notificationFramesAcceptedAnytimeAndDoNotBreakTheWaitForResponse() async throws {
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"schemaVersion":1,"method":"host/log","params":{"level":"info","message":"hi"}}"#)
        transport.enqueue(
            #"{"schemaVersion":1,"method":"host/notify","params":{"kind":"authExpired","detail":null}}"#
        )
        transport.enqueue(#"{"schemaVersion":1,"id":2,"result":{"calendars":[]}}"#)

        let calendars = try await hub.listCalendars(source: StdioHarness.source)

        XCTAssertEqual(calendars, [], "уведомления не мешают дойти до настоящего ответа")
        let logged = await hub.loggedEntries(for: StdioHarness.source)
        let notified = await hub.recordedNotifications(for: StdioHarness.source)
        XCTAssertEqual(logged.map(\.message), ["hi"])
        XCTAssertEqual(notified.map(\.kind), [.authExpired])
    }

    // MARK: - К48 (§2, §5 — кадрирование)

    func test_k48_inputA_frameLongerThan8MiBIsProtocolViolation() async throws {
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        let huge = String(repeating: "x", count: 9 * 1024 * 1024)
        transport.enqueue(#"{"schemaVersion":1,"id":2,"result":{"calendars":[]},"huge":""# + huge + "\"}")

        await assertListCalendarsFails(hub)
    }

    func test_k48_inputB_unparsableFrameIsProtocolViolation() async throws {
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue("это не json вовсе")

        await assertListCalendarsFails(hub)
    }

    func test_k48_inputC_duplicateKeyIsProtocolViolation() async throws {
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"schemaVersion":1,"schemaVersion":1,"id":2,"result":{"calendars":[]}}"#)

        await assertListCalendarsFails(hub)
    }

    func test_k48_inputD_nonCanonicalDateFieldIsProtocolViolation() async throws {
        // Целочисленное поле вне канонической формы — то же самое отображение, тем же путём,
        // покрыто К51 (`schemaVersion` конверта) отдельным тестом ниже; здесь — половина
        // вектора, специфичная payload'у события (`Date`): пробел вместо `T` вне грамматики
        // §0.4 (`YYYY-MM-DDThh:mm:ss[.f{1,9}](Z|±hh:mm)`).
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(Self.fetchEventsResultFrame(id: 2, events: [
            Self.eventJSON(start: "2024-01-01 00:00:00.000Z")
        ]))

        let results = await hub.sync(trigger: .manual)
        Self.assertFailureIsProtocolViolation(results.first?.failure, "не-канонической дате")
    }

    private func assertListCalendarsFails(_ hub: CalendarPortImpl, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await hub.listCalendars(source: StdioHarness.source)
            XCTFail("ожидался protocolViolation", file: file, line: line)
        } catch let error as CalendarError {
            guard case .protocolViolation = error else {
                return XCTFail("ожидался .protocolViolation, получено \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("неожиданный тип ошибки: \(error)", file: file, line: line)
        }
    }

    // MARK: - К49 (инв. 10 — один негодный объект отбрасывает весь ответ)

    func test_k49_oneInvalidEventInFetchEventsResponseDiscardsWholeResponse() async throws {
        let (hub, transport, _, _) = StdioHarness.make()
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
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(Self.fetchEventsResultFrame(id: 2, events: [Self.eventJSON(includeId: true)]))

        let results = await hub.sync(trigger: .manual)
        Self.assertFailureIsProtocolViolation(results.first?.failure, "ключ id в payload")
    }

    func test_k50_inputB_c001InvariantViolationIsRejected() async throws {
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        // `organizer.email` без `@` — нарушение C-001, не приведённое к `nil` источником.
        transport.enqueue(Self.fetchEventsResultFrame(id: 2, events: [
            Self.eventJSON(organizerJSON: #"{"email":"not-an-email","name":null}"#)
        ]))

        let results = await hub.sync(trigger: .manual)
        Self.assertFailureIsProtocolViolation(results.first?.failure, "нарушение инварианта C-001")
    }

    private static func assertFailureIsProtocolViolation(
        _ failure: CalendarError?, _ label: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .protocolViolation = failure else {
            return XCTFail("\(label): ожидался .protocolViolation, получено \(String(describing: failure))",
                            file: file, line: line)
        }
    }

    private static func fetchEventsResultFrame(id: Int, events: [String]) -> String {
        #"{"schemaVersion":1,"id":\#(id),"result":{"events":[\#(events.joined(separator: ","))]}}"#
    }

    private static func eventJSON(
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
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"schemaVersion":2,"id":2,"result":{"calendars":[]}}"#)

        await assertListCalendarsFails(hub)
    }

    func test_k51_schemaVersionMissingIsProtocolViolation() async throws {
        let (hub, transport, _, _) = StdioHarness.make()
        transport.enqueue(StdioHarness.initializeFrame(id: 1))
        transport.enqueue(#"{"id":2,"result":{"calendars":[]}}"#)

        await assertListCalendarsFails(hub)
    }

    // MARK: - К52 (§7 — манифест, разбор байт тем же декодером, что кадры)

    func test_k52_manifestDuplicateKeyRejectedSameMechanismAsFrames() {
        let bytes = Data(#"""
        {"schemaVersion":1,"schemaVersion":1,"id":"p","name":"P","version":"1.0",
         "protocolVersion":"1.0","executable":"./p","args":[],"networkHosts":[],"hostServices":[]}
        """#.utf8)

        XCTAssertThrowsError(try PluginManifestLoader.parse(bytes))
    }

    // MARK: - К53 (§7 — schemaVersion/protocolVersion манифеста)

    func test_k53_manifestSchemaVersionMismatchRejectsWhole() {
        let bytes = Self.manifestJSON(schemaVersion: 2, protocolVersion: "1.0")
        XCTAssertThrowsError(try PluginManifestLoader.parse(bytes)) { error in
            XCTAssertEqual(error as? PluginManifestError, .unsupportedSchemaVersion(found: 2, supported: 1))
        }
    }

    func test_k53_manifestIncompatibleMajorProtocolVersionRejectsBeforeInitialize() {
        let bytes = Self.manifestJSON(schemaVersion: 1, protocolVersion: "2.0")
        XCTAssertThrowsError(try PluginManifestLoader.parse(bytes)) { error in
            XCTAssertEqual(error as? PluginManifestError, .incompatibleProtocolMajor(found: "2.0", supportedMajor: 1))
        }
    }

    func test_k53_manifestMinorVersionDifferenceIsNotFatal() throws {
        let bytes = Self.manifestJSON(schemaVersion: 1, protocolVersion: "1.9")
        let manifest = try PluginManifestLoader.parse(bytes)
        XCTAssertEqual(manifest.protocolVersion, "1.9")
    }

    private static func manifestJSON(schemaVersion: Int, protocolVersion: String) -> Data {
        Data(#"""
        {"schemaVersion":\#(schemaVersion),"id":"p","name":"P","version":"1.0",
         "protocolVersion":"\#(protocolVersion)","executable":"./p","args":[],"networkHosts":[],
         "hostServices":[]}
        """#.utf8)
    }

    // MARK: - К54 (§5.1 — таблица отображения кодов, векторы с собственным кодом)

    private struct ErrorMappingVector {
        let name: String
        let code: Int
        let message: String
        let data: String?
        let expected: CalendarError
    }

    private static let errorMappingVectors: [ErrorMappingVector] = [
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
              expected: .protocolViolation(sourceId: StdioHarness.source, message: "код вне диапазона: -1")),
    ]

    func test_k54_errorMappingTableCodeDrivenRowsPlusSourceId() async throws {
        for vector in Self.errorMappingVectors {
            let (hub, transport, _, _) = StdioHarness.make()
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
        let (hub, transport, connectorRepository, _) = StdioHarness.make(deltaSync: true, cursor: "old-cursor")
        transport.enqueue(StdioHarness.initializeFrame(id: 1, deltaSync: true))
        transport.enqueue(StdioHarness.errorFrame(id: 2, code: -32004, message: "cursor invalid"))
        transport.enqueue(#"{"schemaVersion":1,"id":3,"result":{"events":[]}}"#)

        let results = await hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure, "инв. 19 — протухший курсор не выходит наружу")
        XCTAssertNil(connectorRepository.storedRecords.first?.cursor, "курсор забыт")
        XCTAssertEqual(transport.sent.count, 3, "initialize, fetchChanges, fetchEvents (полное окно) — по одному разу")
    }

    func test_k55_repeatedCursorInvalidOnRecoveryFetchEventsSurfacesAsFailure() async throws {
        let (hub, transport, _, _) = StdioHarness.make(deltaSync: true, cursor: "old-cursor")
        transport.enqueue(StdioHarness.initializeFrame(id: 1, deltaSync: true))
        transport.enqueue(StdioHarness.errorFrame(id: 2, code: -32004, message: "cursor invalid"))
        // Новый вектор: резервный fetchEvents ТОЖЕ отвечает -32004 — не забытый третий повтор
        // §5.2 (тот про -32003), а `ConnectorError.protocolViolation`, выходящий наружу.
        transport.enqueue(StdioHarness.errorFrame(id: 3, code: -32004, message: "cursor invalid again"))

        let results = await hub.sync(trigger: .manual)

        guard case .protocolViolation = results.first?.failure else {
            return XCTFail("повторный cursorInvalid обязан выйти наружу, получено \(String(describing: results.first?.failure))")
        }
    }

    // MARK: - К56 (§5.2, инв. 20 — политика повторов)

    /// Каждая физическая попытка (в том числе повтор ТОЙ ЖЕ логической операции) — отдельный
    /// исходящий `request` со своим `id` (К46, «id не переиспользуется») — счётчик здесь
    /// строго повторяет `StdioCalendarConnector.nextId`, чтобы не считать вручную в каждом
    /// тесте и не разъехаться с реальной последовательностью на лишнем/забытом повторе.
    private final class IdCounter {
        private var next = 1
        func advance() -> Int { defer { next += 1 }; return next }
    }

    func test_k56_defaultRateLimitedUsesFixedBackoff1_2_4() async throws {
        let (hub, transport, _, waitSeam) = StdioHarness.make()
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await hub.listCalendars(source: StdioHarness.source)

        XCTAssertEqual(waitSeam.durations, [.seconds(1), .seconds(2), .seconds(4)])
    }

    func test_k56_validRetryAfterSecondsUsedVerbatim() async throws {
        let (hub, transport, _, waitSeam) = StdioHarness.make()
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        for _ in 0 ..< 3 {
            transport.enqueue(StdioHarness.errorFrame(
                id: ids.advance(), code: -32003, message: "slow down", data: #"{"retryAfterSeconds":5}"#
            ))
        }
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await hub.listCalendars(source: StdioHarness.source)

        XCTAssertEqual(waitSeam.durations, [.seconds(5), .seconds(5), .seconds(5)])
    }

    func test_k56_retryAfterSecondsCeilingIsSixty() async throws {
        let (hub, transport, _, waitSeam) = StdioHarness.make()
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(StdioHarness.errorFrame(
            id: ids.advance(), code: -32003, message: "slow down", data: #"{"retryAfterSeconds":3600}"#
        ))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await hub.listCalendars(source: StdioHarness.source)

        XCTAssertEqual(waitSeam.durations, [.seconds(60)], "потолок ожидания — 60с, не 3600")
    }

    func test_k56_exhaustionAfterThreeRetriesSurfacesTransportError() async throws {
        let (hub, transport, _, waitSeam) = StdioHarness.make()
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        for _ in 0 ..< 4 {
            transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        }

        do {
            _ = try await hub.listCalendars(source: StdioHarness.source)
            XCTFail("четыре подряд -32003 обязаны исчерпать повторы")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .transport(sourceId: StdioHarness.source, message: "rateLimited, retryAfter=4"))
        }
        XCTAssertEqual(waitSeam.durations, [.seconds(1), .seconds(2), .seconds(4)], "ровно три задержки, не четыре")
    }

    func test_k56_initializeAlsoParticipatesInRetryPolicy() async throws {
        let (hub, transport, _, waitSeam) = StdioHarness.make()
        let ids = IdCounter()
        for _ in 0 ..< 3 {
            transport.enqueue(StdioHarness.errorFrame(id: ids.advance(), code: -32003, message: "slow down"))
        }
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        let calendars = try await hub.listCalendars(source: StdioHarness.source)

        XCTAssertEqual(calendars, [])
        XCTAssertEqual(waitSeam.durations, [.seconds(1), .seconds(2), .seconds(4)], "initialize тоже повторяется")
    }

    func test_k56_nonIntegerRetryAfterSecondsFallsBackToFixedDelay() async throws {
        let (hub, transport, _, waitSeam) = StdioHarness.make()
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(StdioHarness.errorFrame(
            id: ids.advance(), code: -32003, message: "slow down", data: #"{"retryAfterSeconds":1.5}"#
        ))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await hub.listCalendars(source: StdioHarness.source)

        XCTAssertEqual(waitSeam.durations, [.seconds(1)], "1.5 не целое — фолбэк, не округление")
    }

    /// Отдельно от `1.5`: `1e400` вне представимости `Double` на переполнении экспоненты — §2
    /// прямо предупреждает, что поведение разборщика Foundation здесь НЕ описано ни одним
    /// документом и вправе отличаться между Linux и Darwin (МЕЕ-361, «К56, вектор 1e400») —
    /// единственный вектор всего перечня, где кросс-платформенное тождество САМО часть
    /// критерия. Отдельный тест — если платформы разойдутся, красным станет только этот
    /// вектор, не увлекая за собой соседний `1.5` (обычное нецелое число, без такого риска).
    func test_k56_overflowRetryAfterSecondsFallsBackToFixedDelay() async throws {
        let (hub, transport, _, waitSeam) = StdioHarness.make()
        let ids = IdCounter()
        transport.enqueue(StdioHarness.initializeFrame(id: ids.advance()))
        transport.enqueue(StdioHarness.errorFrame(
            id: ids.advance(), code: -32003, message: "slow down", data: #"{"retryAfterSeconds":1e400}"#
        ))
        transport.enqueue(#"{"schemaVersion":1,"id":\#(ids.advance()),"result":{"calendars":[]}}"#)

        _ = try await hub.listCalendars(source: StdioHarness.source)

        XCTAssertEqual(waitSeam.durations, [.seconds(1)])
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
