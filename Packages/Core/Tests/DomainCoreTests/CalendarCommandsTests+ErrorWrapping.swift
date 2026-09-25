//  CalendarCommandsTests+ErrorWrapping — wrap(_:CalendarError), §3.1 (возврат РП, приёмка
//  12:00 UTC, находка 3). Разведено из `CalendarCommandsTests.swift` по объёму
//  (`type_body_length`), не по смыслу — см. заголовок того файла. `Fixture`/`makeFixture()` —
//  там же, не `private`.

import XCTest
@testable import DomainCore
import DomainTestKit

extension CalendarCommandsTests {

    private struct CalendarErrorRow {
        let error: CalendarError
        let expectedCode: String
    }

    private func calendarErrorRows(sourceId: CalendarSourceId) -> [CalendarErrorRow] {
        [
            CalendarErrorRow(error: .notConfigured(sourceId: sourceId), expectedCode: "calendar.notConfigured"),
            CalendarErrorRow(
                error: .authorizationRequired(sourceId: sourceId), expectedCode: "calendar.authorizationRequired"
            ),
            CalendarErrorRow(
                error: .transport(sourceId: sourceId, message: "m"), expectedCode: "calendar.transport"
            ),
            CalendarErrorRow(
                error: .protocolViolation(sourceId: sourceId, message: "m"), expectedCode: "calendar.protocolViolation"
            ),
            CalendarErrorRow(
                error: .timeout(sourceId: sourceId, seconds: 5), expectedCode: "calendar.timeout"
            ),
            CalendarErrorRow(error: .cancelled, expectedCode: "calendar.cancelled")
        ]
    }

    /// Все шесть случаев `CalendarError` — код строится правилом `calendar.<имя case>`, тем
    /// же приёмом, что К27 у `StorageError`/`PermissionsError` (`ErrorDictionaryTests.swift`).
    /// Проведено через `beginConnectorAuth` — любой из шести методов группы О одинаково
    /// зовёт один и тот же `wrap(_:CalendarError)`.
    func test_wrapCalendarError_codePerCase() async throws {
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        for row in calendarErrorRows(sourceId: sourceId) {
            let fixture = makeFixture()
            fixture.calendar.fail(with: row.error, on: .beginAuth, source: sourceId)

            do {
                _ = try await fixture.facade.beginConnectorAuth(sourceId: sourceId)
                XCTFail("\(row.error): ожидался отказ")
            } catch AppFacadeError.underlying(let view) {
                XCTAssertEqual(view.code, row.expectedCode, "\(row.error)")
            }
        }
    }

    private struct ConnectorTypeVector {
        let sourceId: String
        let type: String
        let expected: PermissionKind?
    }

    /// `permissionKind` для `.authorizationRequired` — по `ConnectorRecord.type`, НЕ по
    /// `sourceId.rawValue` (возврат РП, приёмка 12:00 UTC, находка 3, `AppFacadeImpl+
    /// Calendar.swift:164` на момент возврата). Три вектора: stdio-тип → `nil`; имя источника
    /// НЕ "eventkit", но тип "eventkit" → `.calendars` (отличает проверку по типу от проверки
    /// по имени в одну сторону); имя источника "eventkit", но тип "stdio" → `nil` (отличает в
    /// другую сторону — старая, забракованная реализация сверяла бы имя и дала `.calendars`
    /// здесь).
    func test_wrapCalendarError_permissionKindByConnectorTypeNotBySourceName() async throws {
        let vectors = [
            ConnectorTypeVector(sourceId: "stdio-plugin", type: "stdio", expected: nil),
            ConnectorTypeVector(sourceId: "graph-work", type: "eventkit", expected: .calendars),
            ConnectorTypeVector(sourceId: "eventkit", type: "stdio", expected: nil)
        ]
        for vector in vectors {
            let fixture = makeFixture()
            let sourceId = CalendarSourceId(rawValue: vector.sourceId)
            fixture.repositories.connectors.seed([ConnectorRecord(
                id: vector.sourceId, type: vector.type, pluginId: nil, settingsJson: Data(),
                keychainNamespace: vector.sourceId, selectedCalendarIds: [], isEnabled: true,
                lastSyncAt: nil, cursor: nil, lastError: nil
            )])
            fixture.calendar.fail(with: .authorizationRequired(sourceId: sourceId), on: .beginAuth, source: sourceId)

            do {
                _ = try await fixture.facade.beginConnectorAuth(sourceId: sourceId)
                XCTFail("\(vector.sourceId)/\(vector.type): ожидался отказ")
            } catch AppFacadeError.underlying(let view) {
                XCTAssertEqual(view.permissionKind, vector.expected, "\(vector.sourceId)/\(vector.type)")
            }
        }
    }

    /// Источник без записи в `ConnectorRepository` — тип определить не из чего,
    /// `permissionKind == nil` (не `.calendars` по умолчанию).
    func test_wrapCalendarError_unknownConnectorGivesNilPermissionKind() async throws {
        let fixture = makeFixture()
        let sourceId = CalendarSourceId(rawValue: "eventkit")
        fixture.calendar.fail(with: .authorizationRequired(sourceId: sourceId), on: .beginAuth, source: sourceId)

        do {
            _ = try await fixture.facade.beginConnectorAuth(sourceId: sourceId)
            XCTFail("ожидался отказ")
        } catch AppFacadeError.underlying(let view) {
            XCTAssertNil(view.permissionKind, "неизвестный коннектор — тип не определён")
        }
    }
}
