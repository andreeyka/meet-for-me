//  CalendarCommandsTests — К39, К40 (группа О плана MEE-410, перечень MEE-401, C-016 v10,
//  MEE-441).
//
//  ФИКСТУРА ОТСТУПАЕТ ОТ КОЛОНКИ ПЛАНА НА ОДНОМ МЕСТЕ, НАЗВАНО ПРЯМО. План/перечень называют
//  фикстурой К39/К40 только ФКП (`FakeCalendarPort`) и описывают все четыре метода К39
//  (включая `setConnectorEnabled`) как «сквозные, 1:1 оборачивающие CalendarPort». Буквально
//  это неверно для `setConnectorEnabled` — у `CalendarPort` (13 методов, сверено чтением
//  файла целиком) нет ни одного про включение/выключение источника; см. докстринг
//  `AppFacadeImpl+Calendar.swift` за полным разбором и живым прецедентом (`CalendarPortImpl`
//  сам читает `ConnectorRepository.isEnabled` напрямую, минуя порт). Тест на
//  `setConnectorEnabled` поэтому использует ФКоР (`InMemoryConnectorRepository`) вместо ФКП —
//  то, что производственный код действительно вызывает, а не то, что называет колонка плана
//  буквально. Тот же класс решения, что `editSegmentText`/`transcriptId(forSegmentId:)`
//  (МЕЕ-437) — задокументированное расхождение с буквой, а не немой пропуск.

import XCTest
@testable import DomainCore
import DomainTestKit

final class CalendarCommandsTests: XCTestCase {

    private struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let calendar: FakeCalendarPort
    }

    private func makeFixture() -> Fixture {
        let repositories = InMemoryRepositories()
        let calendar = FakeCalendarPort(log: repositories.log)
        let facade = AppFacadeImpl(
            meetings: repositories.meetings,
            recordings: repositories.recordings,
            transcripts: repositories.transcripts,
            persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: Date()),
            modelCatalog: FakeModelCatalogPort(),
            calendar: calendar,
            sessionCoordinator: NoOpSessionCoordinator(),
            attribution: FakeAttributionPort(),
            settings: repositories.settings,
            connectors: repositories.connectors,
            clock: { Date() }
        )
        return Fixture(facade: facade, repositories: repositories, calendar: calendar)
    }

    // MARK: - К39: beginConnectorAuth — AuthChallenge целиком, без разбора

    /// `redirectScheme` доезжает тем же значением, что отдал `CalendarPort.beginAuth`
    /// (IR-120, C-016 v7) — критический вектор находки v7, сверяется прямым равенством
    /// `AuthChallenge`, не только одного поля.
    func test_k39_beginConnectorAuth_returnsAuthChallengeUnchanged() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let challenge = AuthChallenge(authUrl: URL(string: "https://example.com/oauth")!, redirectScheme: "meetforme")
        fixture.calendar.setAuthChallenge(challenge, for: sourceId)

        let result = try await fixture.facade.beginConnectorAuth(sourceId: sourceId)

        XCTAssertEqual(result, challenge)
        XCTAssertEqual(fixture.repositories.log.count(port: "CalendarPort", method: "beginAuth(source:)"), 1)
    }

    /// К39: отказ `CalendarPort.beginAuth` уходит как `.underlying` по словарю §3.1 —
    /// `wrap(_:CalendarError)` (`AppFacadeImpl+Calendar.swift`), впервые достижимый этой
    /// задачей (см. докстринг `ErrorDictionaryTests.swift`, «ВНЕ ДОСЯГАЕМОСТИ»).
    func test_k39_beginConnectorAuth_wrapsCalendarError() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        fixture.calendar.fail(with: .authorizationRequired(sourceId: sourceId), on: .beginAuth, source: sourceId)

        do {
            _ = try await fixture.facade.beginConnectorAuth(sourceId: sourceId)
            XCTFail("ожидался отказ")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "calendar.authorizationRequired")
            XCTAssertEqual(view.permissionKind, .calendars, "eventkit — встроенный коннектор, право .calendars")
        }
    }

    // MARK: - К39: completeConnectorAuth — сквозной результат, .statusChanged на успехе

    func test_k39_completeConnectorAuth_wrapsCalendarPortResultAndPublishesStatusChanged() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let stream = fixture.facade.events()

        let result = try await fixture.facade.completeConnectorAuth(
            sourceId: sourceId, callbackUrl: URL(string: "meetforme://callback?code=1")!
        )

        XCTAssertNil(result, "ФКП отвечает nil, пока не задан отказ — см. докстринг FakeCalendarPort")
        XCTAssertEqual(
            fixture.repositories.log.count(port: "CalendarPort", method: "completeAuth(source:callbackUrl:)"), 1
        )
        let events = await collectEvents(stream, count: 1)
        guard case .statusChanged = events.first else {
            return XCTFail("ожидался .statusChanged, получено \(events)")
        }
    }

    // MARK: - К39: setConnectorEnabled — через ConnectorRepository, не CalendarPort (см. докстринг файла)

    /// Существующая запись: `isEnabled` меняется, `upsert` вызван ровно раз, `CalendarPort`
    /// не вызван ни разу (см. докстринг файла и `AppFacadeImpl+Calendar.swift`).
    func test_k39_setConnectorEnabled_flipsStoredRecord() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let record = ConnectorRecord(
            id: sourceId.rawValue, type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: "eventkit", selectedCalendarIds: [], isEnabled: false,
            lastSyncAt: nil, cursor: nil, lastError: nil
        )
        fixture.repositories.connectors.seed([record])

        try await fixture.facade.setConnectorEnabled(true, sourceId: sourceId)

        let stored = try await fixture.repositories.connectors.all()
        XCTAssertEqual(stored.first?.isEnabled, true)
        XCTAssertEqual(fixture.repositories.log.count(port: "ConnectorRepository", method: "upsert(_:)"), 1)
        XCTAssertTrue(
            fixture.repositories.log.calls(port: "CalendarPort").isEmpty,
            "setConnectorEnabled не вызывает CalendarPort ни разу — см. докстринг файла реализации"
        )
    }

    /// Неизвестный `sourceId` — `CalendarError.notConfigured(sourceId:)`, тот же case и по
    /// той же причине, что `CalendarPortImpl.requireRecord` бросает для неизвестного
    /// источника (`CalendarHub/CalendarPortImpl.swift`) — не новый словарный код.
    func test_k39_setConnectorEnabled_unknownSourceThrowsNotConfigured() async throws {
        let fixture = makeFixture()

        do {
            try await fixture.facade.setConnectorEnabled(true, sourceId: CalendarSourceId(rawValue: "unknown"))
            XCTFail("ожидался отказ")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "calendar.notConfigured")
        }
    }

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
