//  К30 (отказ протокола одного источника не задевает остальные), К31 (тот же externalId в
//  разных циклах fetchEvents сходится на одну запись обоими признаками согласованно), К37
//  (развилка Р3 — отказ источника не стирает уже сохранённые встречи).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class SyncFailureIsolationTests: XCTestCase {

    /// Вход: src-1 бросает `ConnectorError.protocolViolation` на `fetchEvents`, src-2
    /// синхронизируется штатно. Ответ: src-1 получает `CalendarError.protocolViolation`
    /// в своём `CalendarSyncResult.failure`, src-2 остаётся `failure == nil` — К15 (MEE-339)
    /// закрепляет то же отображение на уровне одного вызова, здесь — что оно не течёт
    /// на СОСЕДНИЙ источник в рамках одного `sync(trigger:)`.
    func test_k30_singleSourceProtocolViolationDoesNotAffectOtherSources() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        harness.connector("src-1").fail(.fetchEvents, with: .protocolViolation(message: "malformed"))
        harness.connector("src-2").setFetchEvents([])

        let results = await harness.hub.sync(trigger: .manual)

        let resultA = results.first { $0.sourceId == CalendarSourceId(rawValue: "src-1") }
        let resultB = results.first { $0.sourceId == CalendarSourceId(rawValue: "src-2") }
        guard case .protocolViolation(let sourceId, _) = resultA?.failure else {
            XCTFail("src-1 обязан получить CalendarError.protocolViolation")
            return
        }
        XCTAssertEqual(sourceId, CalendarSourceId(rawValue: "src-1"))
        XCTAssertNil(resultB?.failure, "src-2 не задет отказом src-1")
    }

    /// Вход: первый `fetchEvents` отдаёт `externalId == "evt-1"`; второй цикл (следующий
    /// `sync`) — тот же `externalId`, тот же `icalUid`/`start` (та же формула DedupKey),
    /// обновлённый `lastModified`. Ответ: второй цикл находит существующую запись по
    /// признаку (а) — обновляет её тем же `id`, не заводит вторую встречу; пара
    /// (`sourceConnectorId`, `externalId`) тоже совпадает — оба признака согласованы.
    func test_k31_sameExternalIdAcrossCyclesUpdatesSameRecordConsistently() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let connector = harness.connector("src-1")
        connector.setFetchEvents([try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base)])

        _ = await harness.hub.sync(trigger: .manual)
        let firstStored = harness.meetingRepository.storedRecords
        XCTAssertEqual(firstStored.count, 1)
        let recordId = try XCTUnwrap(firstStored.first?.event.id)

        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base.addingTimeInterval(60))
        ])
        _ = await harness.hub.sync(trigger: .manual)

        let secondStored = harness.meetingRepository.storedRecords
        XCTAssertEqual(secondStored.count, 1, "второй цикл не создаёт вторую встречу")
        XCTAssertEqual(secondStored.first?.event.id, recordId, "тот же id — признак (а) находит существующую запись")
        XCTAssertTrue(
            secondStored.first?.sources.contains { $0.sourceConnectorId == "src-1" && $0.externalId == "evt-1" }
                ?? false,
            "пара (sourceConnectorId, externalId) тоже совпадает — оба признака согласованно указывают на ту же запись"
        )
    }

    /// Развилка Р3: отказ источника не меняет сохранённое состояние ни в одной строке.
    /// Вход: источник с уже сохранёнными тремя встречами; очередной `sync` для него отдаёт
    /// `ConnectorError.upstreamUnavailable`. Ответ: все три остаются неизменными,
    /// `failure != nil`, `deletedCount == 0`.
    func test_k37_failureDoesNotErasePreviouslyStoredMeetings() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let connector = harness.connector("src-1")
        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base),
            try mergeTestPayload(
                connectorId: "src-1", externalId: "evt-2", lastModified: base, start: base.addingTimeInterval(3_600)
            ),
            try mergeTestPayload(
                connectorId: "src-1", externalId: "evt-3", lastModified: base, start: base.addingTimeInterval(7_200)
            )
        ])
        _ = await harness.hub.sync(trigger: .manual)
        XCTAssertEqual(harness.meetingRepository.storedRecords.count, 3)

        connector.fail(.fetchEvents, with: .upstreamUnavailable(message: "недоступен"))
        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNotNil(results.first?.failure)
        XCTAssertEqual(results.first?.deletedCount, 0)
        XCTAssertEqual(
            harness.meetingRepository.storedRecords.count, 3, "отказ источника не стирает ранее сохранённые встречи"
        )
    }
}
