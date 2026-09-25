//  CalendarCommandsTests+K40 — К40 (группа О плана MEE-410, перечень MEE-401, C-016 v10,
//  MEE-441). Разведено из `CalendarCommandsTests.swift` по объёму (`type_body_length`), не
//  по смыслу — см. заголовок того файла. `Fixture`/`makeFixture()` — там же, не `private`.

import XCTest
@testable import DomainCore
import DomainTestKit

extension CalendarCommandsTests {

    // MARK: - К40: connectorSettingsSchema/configureConnector — байты не разобраны

    /// Байты `CalendarPort.settingsSchema` возвращаются как есть — даже заведомо невалидный
    /// для JSON Schema набор байт не бросает здесь (критерий проверяет отсутствие разбора).
    func test_k40_connectorSettingsSchema_returnsCalendarPortBytesUnparsed() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let invalidSchema = Data([0xFF, 0x00, 0xDE, 0xAD])
        fixture.calendar.setSettingsSchema(invalidSchema, for: sourceId)

        let result = try await fixture.facade.connectorSettingsSchema(sourceId: sourceId)

        XCTAssertEqual(result, invalidSchema)
    }

    /// `configure` вызван ровно раз, байты переданы без разбора; успех не бросает.
    func test_k40_configureConnector_passesBytesThroughUnparsedAndPublishesStatusChanged() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let settings = Data([0x01, 0x02, 0x03])
        let stream = fixture.facade.events()

        try await fixture.facade.configureConnector(sourceId: sourceId, settings: settings)

        XCTAssertEqual(fixture.calendar.configuredSettings(for: sourceId), settings)
        XCTAssertEqual(fixture.repositories.log.count(port: "CalendarPort", method: "configure(source:settings:)"), 1)
        let events = await collectEvents(stream, count: 1)
        guard case .statusChanged = events.first else {
            return XCTFail("ожидался .statusChanged, получено \(events)")
        }
    }

    /// На невалидных (по мнению порта) байтах `configure` бросает — фасад сам байты не
    /// проверяет, отказ порта пробрасывается как `.underlying` (словарь §3.1).
    func test_k40_configureConnector_invalidBytesPropagatesCalendarError() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        fixture.calendar.fail(with: .protocolViolation(sourceId: sourceId, message: "bad schema"), on: .configure)

        do {
            try await fixture.facade.configureConnector(sourceId: sourceId, settings: Data([0x00]))
            XCTFail("ожидался отказ")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "calendar.protocolViolation")
        }
    }

    // MARK: - К40: connectorHealth — ConnectorHealthView, не сырой ConnectorHealth

    /// Супермножество полей (IR-120, C-016 v7): `status`/`message`/`lastSyncAt` — от
    /// `CalendarPort.healthCheck`; `isEnabled` — от `ConnectorRepository`, если запись есть.
    func test_k40_connectorHealth_returnsConnectorHealthViewSupersetOfRawHealth() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let moment = Date(timeIntervalSince1970: 1_000)
        fixture.calendar.setConnectorHealth(
            ConnectorHealth(status: .degraded, message: "нужна повторная авторизация", lastSuccessfulSyncAt: moment),
            for: sourceId
        )
        fixture.repositories.connectors.seed([ConnectorRecord(
            id: sourceId.rawValue, type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: "eventkit", selectedCalendarIds: [], isEnabled: true,
            lastSyncAt: nil, cursor: nil, lastError: nil
        )])

        let view = try await fixture.facade.connectorHealth(sourceId: sourceId)

        XCTAssertEqual(view.sourceId, sourceId)
        XCTAssertEqual(view.status, .degraded)
        XCTAssertEqual(view.message, "нужна повторная авторизация")
        XCTAssertEqual(view.lastSyncAt, moment)
        XCTAssertEqual(view.isEnabled, true)
    }

    /// Возврат РП (приёмка 12:00 UTC, «мелочи»): второй вектор `isEnabled` — `false`, не
    /// только `true`, — чтобы поле не сходило за случайно верное умолчание.
    func test_k40_connectorHealth_isEnabledFalseVector() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        fixture.calendar.setConnectorHealth(
            ConnectorHealth(status: .ok, message: nil, lastSuccessfulSyncAt: nil), for: sourceId
        )
        fixture.repositories.connectors.seed([ConnectorRecord(
            id: sourceId.rawValue, type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: "eventkit", selectedCalendarIds: [], isEnabled: false,
            lastSyncAt: nil, cursor: nil, lastError: nil
        )])

        let view = try await fixture.facade.connectorHealth(sourceId: sourceId)

        XCTAssertEqual(view.isEnabled, false)
    }

    // MARK: - К40: stopConnectors — не метод протокола (мех.-половина)

    /// `stopConnectors` не входит в протокол `AppFacade` — снят v7 контракта (C-016), звонит
    /// `CalendarPort.stop()` напрямую composition root, не через фасад. Читает исходный текст
    /// протокола через `#filePath`, тем же приёмом, что К1 (`AppFacadeGeneralTests.swift`) —
    /// не компиляцией (`grep`-проверка живого исходника, не своё же утверждение).
    func test_k40_stopConnectorsIsNotAProtocolMethod() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        url = url.appendingPathComponent("Sources").appendingPathComponent("DomainCore")
            .appendingPathComponent("AppFacade.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(source.contains("stopConnectors"), "AppFacade — протокол не должен объявлять stopConnectors")
    }
}
