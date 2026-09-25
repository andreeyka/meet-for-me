//  CalendarCommandsTests — К39, К40 (группа О плана MEE-410, перечень MEE-401, C-016 v10,
//  MEE-441). Разведено на три файла по объёму (`type_body_length`, SwiftLint `--strict`
//  краснит уже на предупреждении): этот — фикстура + К39 (`beginConnectorAuth`/
//  `completeConnectorAuth`/`setConnectorEnabled`); `CalendarCommandsTests+K40.swift` — К40;
//  `CalendarCommandsTests+ErrorWrapping.swift` — табличный тест `wrap(_:CalendarError)`.
//  Общие `Fixture`/`makeFixture()` — здесь, не `private` (тот же приём, что `EventsTests.swift`
//  для своих файлов-расширений).
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

    struct Fixture {
        let facade: AppFacadeImpl
        let repositories: InMemoryRepositories
        let calendar: FakeCalendarPort
    }

    func makeFixture() -> Fixture {
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
    /// `permissionKind` — по `ConnectorRecord.type` (возврат РП, приёмка 12:00 UTC,
    /// находка 3), поэтому запись коннектора здесь задана явно — точные векторы по типу vs
    /// имени источника см. `CalendarCommandsTests+ErrorWrapping.swift`.
    func test_k39_beginConnectorAuth_wrapsCalendarError() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        fixture.repositories.connectors.seed([ConnectorRecord(
            id: sourceId.rawValue, type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: sourceId.rawValue, selectedCalendarIds: [], isEnabled: true,
            lastSyncAt: nil, cursor: nil, lastError: nil
        )])
        fixture.calendar.fail(with: .authorizationRequired(sourceId: sourceId), on: .beginAuth, source: sourceId)

        do {
            _ = try await fixture.facade.beginConnectorAuth(sourceId: sourceId)
            XCTFail("ожидался отказ")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertEqual(view.code, "calendar.authorizationRequired")
            XCTAssertEqual(view.permissionKind, .calendars, "тип коннектора eventkit — право .calendars")
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

    /// Возврат РП (приёмка 12:00 UTC, «мелочи»): ФКП по умолчанию отвечает `nil`, так что
    /// проброс НЕПУСТОЙ строки раньше не проверялся — `setCompleteAuthResult(_:for:)`
    /// (МЕЕ-441) задаёт канонический ответ.
    func test_k39_completeConnectorAuth_passesThroughNonEmptyResult() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        fixture.calendar.setCompleteAuthResult("state-abc123", for: sourceId)

        let result = try await fixture.facade.completeConnectorAuth(
            sourceId: sourceId, callbackUrl: URL(string: "meetforme://callback?code=1")!
        )

        XCTAssertEqual(result, "state-abc123")
    }

    // MARK: - К39: setConnectorEnabled — через ConnectorRepository, не CalendarPort (см. докстринг файла)

    /// Существующая запись: `isEnabled` меняется, `upsert` вызван ровно раз, `CalendarPort`
    /// не вызван ни разу (см. докстринг файла и `AppFacadeImpl+Calendar.swift`). Инв. 15
    /// (возврат РП, приёмка 12:00 UTC, находка 2): публикует `.statusChanged`.
    func test_k39_setConnectorEnabled_flipsStoredRecordAndPublishesStatusChanged() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        let record = ConnectorRecord(
            id: sourceId.rawValue, type: "eventkit", pluginId: nil, settingsJson: Data(),
            keychainNamespace: "eventkit", selectedCalendarIds: [], isEnabled: false,
            lastSyncAt: nil, cursor: nil, lastError: nil
        )
        fixture.repositories.connectors.seed([record])
        let stream = fixture.facade.events()

        try await fixture.facade.setConnectorEnabled(true, sourceId: sourceId)

        let stored = try await fixture.repositories.connectors.all()
        XCTAssertEqual(stored.first?.isEnabled, true)
        XCTAssertEqual(fixture.repositories.log.count(port: "ConnectorRepository", method: "upsert(_:)"), 1)
        XCTAssertTrue(
            fixture.repositories.log.calls(port: "CalendarPort").isEmpty,
            "setConnectorEnabled не вызывает CalendarPort ни разу — см. докстринг файла реализации"
        )
        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)
        guard case .statusChanged = events.first else {
            return XCTFail("ожидался .statusChanged, получено \(events)")
        }
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
}
