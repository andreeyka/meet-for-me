//  Группа Ж плана MEE-361 (К46-К56, C-006 §2/§5/§5.1/§5.2/§7) — хост stdio через
//  `ScriptedRPCTransport`/`StdioCalendarConnector` (MEE-402 шаг 2). К57-К65 — отдельные файлы
//  (уже написаны частями 3и/3з, некоторые уже упоминают Ш2 в MEE-361 не как новый тест, а как
//  учёт: К64/К65 полностью проверены транспорт-независимой оснасткой `FakeCalendarConnector`
//  ранее и здесь не повторяются). К1 (MAJOR-вектор рукопожатия `initialize`) — здесь же, ниже
//  (MEE-386). К9 вход Б (кадр `shutdown` на таймауте) и К12 (не более одного stdio-запроса в
//  очереди) — отдельные файлы (`StdioProtocolTests+TimeoutShutdown.swift`,
//  `StdioProtocolTests+RequestQueueing.swift`), но используют этот же `StdioHarness` (MEE-386).
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

/// Не кортеж из четырёх элементов (`StdioHarness.make()`'s прежняя форма) — SwiftLint
/// `large_tuple` (по умолчанию: предел два элемента) считает такой кортеж нарушением;
/// именованные поля читаются на месте вызова не хуже, и линт доволен.
struct StdioHarnessBundle {
    let hub: CalendarPortImpl
    let transport: ScriptedRPCTransport
    let connector: StdioCalendarConnector
    let connectorRepository: InMemoryConnectorRepository
    let waitSeam: FakeWaitSeam
}

enum StdioHarness {
    static let source = CalendarSourceId(rawValue: "src-1")

    static func make(deltaSync: Bool = false, cursor: String? = nil) -> StdioHarnessBundle {
        let transport = ScriptedRPCTransport()
        let connector = StdioCalendarConnector(transport: transport)
        let connectorRepository = InMemoryConnectorRepository(log: PortCallLog())
        let meetingRepository = InMemoryMeetingRepository(log: PortCallLog())
        let waitSeam = FakeWaitSeam()
        // НЕ `setAutoResolve(true)`: `FakeWaitSeam`'s собственный докстринг (TestSupport.swift)
        // прямо предупреждает — авторазрешение делает сон `raceTimeout`'а «мгновенным» и
        // превращает гонку операция/таймаут в монетку планировщика на КАЖДОМ вызове, не
        // только там, где таймаут — часть проверки (найдено буквально: все 21 тест этого
        // файла падали `.timeout` вместо ожидаемого исхода на первом же CI прогоне). Ворота
        // (по умолчанию) держат таймаут повешенным, пока операция естественно не выиграет
        // гонку и `group.cancelAll()` не снимет его, — тот же приём, что у всех остальных
        // файлов `CalendarHubTests`. Задержки повтора §5.2 (К56) — отдельная, НЕ гонящаяся
        // пересылка `waitSeam.sleep(for:)` внутри `callConnector`; тесты К56 отпускают её
        // явно (`callThroughRetries` ниже), а не полагаются на авторазрешение.
        connectorRepository.seed([Harness.record(id: "src-1", cursor: cursor)])
        let hub = CalendarPortImpl(
            connectorRepository: connectorRepository, meetingRepository: meetingRepository,
            waitSeam: waitSeam, secretStore: FakeSecretStore(), connectors: [source: connector]
        )
        return StdioHarnessBundle(
            hub: hub, transport: transport, connector: connector,
            connectorRepository: connectorRepository, waitSeam: waitSeam
        )
    }

    static func initializeFrame(id: Int, deltaSync: Bool = false, protocolVersion: String = "1.0") -> String {
        """
        {"schemaVersion":1,"id":\(id),"result":{\
        "plugin":{"id":"plug","name":"Plug","version":"1.0"},"protocolVersion":"\(protocolVersion)",\
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
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
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
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
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
        // Возврат РП (приёмка #135, п. 3): `notification` не получает ответа (инв. 4) — хост
        // не отправил ничего сверх своих двух исходящих запросов (`initialize`, `listCalendars`),
        // хотя прочитал два входящих `notification`-кадра между ними.
        XCTAssertEqual(transport.sent.count, 2, "на notification ответ не отправляется")
    }

    // MARK: - К1 (C-006 §1 — рукопожатие `initialize`, MAJOR/MINOR `protocolVersion`)

    /// Отдельный вход К1 (MEE-386): `initialize` отвечает `protocolVersion` с MAJOR, не
    /// совпадающим с `RPCHostVersioning.supportedProtocolMajor` (1) — хост считает это
    /// фатальной ошибкой соединения; коннектор не используется дальше в этом цикле (тот же
    /// эффект, что и у любой другой ошибки `initialize` — `capabilities[source]` не кешируется,
    /// см. докстринг `StdioCalendarConnector.initialize`).
    func test_k1_initializeMajorVersionMismatchIsFatalProtocolViolation() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1, protocolVersion: "2.0"))

        do {
            _ = try await hub.listCalendars(source: StdioHarness.source)
            XCTFail("ожидался protocolViolation на несовместимом MAJOR protocolVersion")
        } catch let error as CalendarError {
            guard case .protocolViolation = error else {
                return XCTFail("ожидался .protocolViolation, получено \(error)")
            }
        }

        XCTAssertEqual(transport.sent.count, 1, "коннектор не используется дальше — только initialize ушёл")
    }

    /// Тот же вход, но `MINOR`-расхождение (`"1.9"` против ожидаемого `"1.x"`) — не фатально,
    /// работа продолжается обычным путём.
    func test_k1_initializeMinorVersionMismatchIsNotFatal() async throws {
        let bundle = StdioHarness.make()
        let hub = bundle.hub
        let transport = bundle.transport
        transport.enqueue(StdioHarness.initializeFrame(id: 1, protocolVersion: "1.9"))
        transport.enqueue(#"{"schemaVersion":1,"id":2,"result":{"calendars":[]}}"#)

        let calendars = try await hub.listCalendars(source: StdioHarness.source)

        XCTAssertEqual(calendars, [], "MINOR-расхождение не мешает работе")
        XCTAssertEqual(transport.sent.count, 2, "initialize + listCalendars — оба ушли, работа продолжается")
    }
}
