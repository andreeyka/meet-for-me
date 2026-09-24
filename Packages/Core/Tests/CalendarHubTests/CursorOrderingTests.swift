//  К64 (C-006 §6 fetchChanges → ChangeBatch.cursor): порядок применения пакета относительно
//  сохранения курсора — вход А (обычный успех) и вход Б (setCursor(nil) на протухшем курсоре,
//  тот же вектор, что у К55).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class CursorOrderingTests: XCTestCase {

    /// Вход А: `fetchChanges` возвращает успешный `ChangeBatch` с непустым `cursor` и
    /// непустыми `events`. Ответ: хост сначала применяет пакет (`save`/`delete`), и только
    /// ПОСЛЕ этого — `setCursor`, ровно один раз; порядок проверяется последовательностью
    /// вызовов на фейке, не только фактом обоих вызовов — сохранение курсора раньше данных
    /// пакета рискует потерять сами данные при падении между двумя записями.
    func test_k64_inputA_packetAppliedBeforeCursorSaved() async throws {
        let sharedLog = PortCallLog()
        let harness = Harness(sourceIds: ["src-1"], sharedLog: sharedLog)
        harness.connectorRepository.seed([Harness.record(id: "src-1", cursor: "old-cursor")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: true, push: false, attendees: true, conference: true, auth: .none
        ))
        let payload = try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: Date())
        connector.setFetchChanges(ChangeBatch(
            events: [payload], deletedExternalIds: [], cursor: "abc123", resetRequired: false
        ))

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure)
        XCTAssertEqual(
            sharedLog.count(port: "ConnectorRepository", method: "setCursor(_:connectorId:)"), 1,
            "setCursor вызван ровно один раз"
        )
        XCTAssertTrue(
            sharedLog.happened("MeetingRepository.save(_:)", before: "ConnectorRepository.setCursor(_:connectorId:)"),
            "события пакета применены ДО сохранения его курсора"
        )
        XCTAssertEqual(harness.connectorRepository.storedRecords.first?.cursor, "abc123")
    }

    /// Вход Б (`setCursor(nil)` — протухший курсор, инв. 19, тот же вектор, что в К55, шаг
    /// 1): `fetchChanges` отвечает `-32004`/`cursorInvalid`. Ответ: `ConnectorRepository.
    /// setCursor(nil, connectorId:)` вызывается ПРЕЖДЕ повторного `fetchEvents` — момент
    /// вызова `setCursor(nil)` держит эта проверка отдельно, не полагаясь только на цитату
    /// внутри К55.
    func test_k64_inputB_cursorInvalidClearsCursorBeforeRetryFetchEvents() async throws {
        let sharedLog = PortCallLog()
        let harness = Harness(sourceIds: ["src-1"], sharedLog: sharedLog)
        harness.connectorRepository.seed([Harness.record(id: "src-1", cursor: "old-cursor")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: true, push: false, attendees: true, conference: true, auth: .none
        ))
        connector.fail(.fetchChanges, with: .cursorInvalid)
        connector.setFetchEvents([])

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure, "инв. 19 — протухший курсор не выходит наружу")
        XCTAssertEqual(connector.callCount(.fetchEvents), 1, "полное окно на резервном пути")
        XCTAssertTrue(
            sharedLog.happened(
                "ConnectorRepository.setCursor(_:connectorId:)", before: "CalendarConnector.fetchEvents"
            ),
            "курсор забыт ДО повторного fetchEvents"
        )
        XCTAssertNil(harness.connectorRepository.storedRecords.first?.cursor)
    }
}
