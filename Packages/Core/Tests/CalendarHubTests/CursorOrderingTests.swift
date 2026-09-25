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

    /// Вход А: `fetchChanges` возвращает успешный `ChangeBatch` с непустым `cursor`,
    /// непустыми `events` И непустыми `deletedExternalIds`. Ответ: хост сначала применяет
    /// ВЕСЬ пакет — и `save` (upsert), и `delete` — и только ПОСЛЕ этого — `setCursor`,
    /// ровно один раз; порядок проверяется последовательностью вызовов на фейке, не только
    /// фактом обоих вызовов — сохранение курсора раньше данных пакета рискует потерять
    /// сами данные при падении между двумя записями.
    ///
    /// Возврат РП (приёмка #129, п. 4): прежняя версия проверяла только `save`, не `delete`
    /// — `deletedExternalIds` пакета был пуст, ветка `delete()` в `applyDeltaSync` вообще
    /// не упражнялась этим тестом.
    func test_k64_inputA_packetAppliedBeforeCursorSaved() async throws {
        let sharedLog = PortCallLog()
        let harness = Harness(sourceIds: ["src-1"], sharedLog: sharedLog)
        harness.connectorRepository.seed([Harness.record(id: "src-1", cursor: "old-cursor")])
        let existingId = UUID()
        try Self.seedSingleSourceRecord(harness, id: existingId, externalId: "evt-old")
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: true, push: false, attendees: true, conference: true, auth: .none
        ))
        let payload = try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: Date())
        connector.setFetchChanges(ChangeBatch(
            events: [payload], deletedExternalIds: ["evt-old"], cursor: "abc123", resetRequired: false
        ))

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure)
        XCTAssertEqual(
            sharedLog.count(port: "ConnectorRepository", method: "setCursor(_:connectorId:)"), 1,
            "setCursor вызван ровно один раз"
        )
        XCTAssertTrue(
            sharedLog.happened("MeetingRepository.save(_:)", before: "ConnectorRepository.setCursor(_:connectorId:)"),
            "upsert пакета применён ДО сохранения его курсора"
        )
        XCTAssertTrue(
            sharedLog.happened(
                "MeetingRepository.delete(meetingIds:)", before: "ConnectorRepository.setCursor(_:connectorId:)"
            ),
            "delete пакета применён ДО сохранения его курсора"
        )
        XCTAssertEqual(harness.connectorRepository.storedRecords.first?.cursor, "abc123")
        let deletedEvent = try await harness.hub.event(id: existingId)
        XCTAssertNil(deletedEvent, "evt-old удалён")
    }

    /// Единственный источник записи `externalId` — `delete()` целиком, не частичное
    /// переслияние (см. `removeExternalId`, `CalendarPortImplMerge+SourceDeparture.swift`).
    /// `start` — намеренно ДАЛЕКО от `mergeTestPayload`'s дефолтного 1_700_000_000 (та же
    /// секунда, что у входящего "evt-1" этого теста): разные минуты после округления
    /// инв. 3 дают разный `DedupKey`, иначе оба payload'а сошлись бы на одну запись через
    /// признак (а), хотя это два независимых события с разными `externalId`.
    private static func seedSingleSourceRecord(_ harness: Harness, id: UUID, externalId: String) throws {
        let base = Date(timeIntervalSince1970: 1_600_000_000)
        let payload = try mergeTestPayload(
            connectorId: "src-1", externalId: externalId, lastModified: base, start: base
        )
        let event = try payload.assigningId(id)
        harness.meetingRepository.seed([
            MeetingRecord(
                event: event, dedupKey: DedupKey.make(from: event), status: .ready,
                sources: [
                    MeetingSource(
                        sourceConnectorId: "src-1", externalId: externalId, icalUid: "shared-uid",
                        lastModified: base, payload: payload
                    )
                ]
            )
        ])
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

    /// Возврат РП (приёмка #129, п. 3): развилка Р9 шаг 1 — первая синхронизация
    /// delta-источника (`record.cursor == nil`), `fetchChanges(cursor: nil)` отвечает
    /// `cursorInvalid`. Ответ (`applyFirstDeltaStep`'s catch-ветка): курсора и на этом шаге
    /// уже нет, «протухшего» курсора в обычном смысле инв. 19 здесь нет — трактуется как
    /// «пакета нет» (пустой `SyncOutcome`, `pendingCursor == nil`), БЕЗ собственного
    /// резервного полного окна на этом шаге; шаг 2 (`applyFullWindow`) `fetchAndApply`
    /// всё равно вызывает сама, тем же циклом Р9, независимо от исхода шага 1.
    func test_firstDeltaStepCursorInvalidTreatedAsEmptyBatchThenStepTwoFullWindowRuns() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"], deltaSync: true, cursor: nil)
        let connector = harness.connector("src-1")
        connector.fail(.fetchChanges, with: .cursorInvalid)
        connector.setFetchEvents([])

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure, "cursorInvalid на шаге 1 Р9 не выходит наружу")
        XCTAssertEqual(connector.callCount(.fetchChanges), 1, "шаг 1 — ровно одна попытка, без своего резерва")
        XCTAssertEqual(connector.callCount(.fetchEvents), 1, "шаг 2 (полное окно) выполняется этим же циклом Р9")
        XCTAssertNil(
            harness.connectorRepository.storedRecords.first?.cursor,
            "pendingCursor == nil — fetchAndApply не сохраняет курсор, нечего было вернуть с шага 1"
        )
    }
}
