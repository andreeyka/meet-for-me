//  К38 (развилка Р4 — событие, пропавшее из полного ответа fetchEvents, никогда не
//  публикуется .deleted этим путём — ни состарившись за нижнюю границу окна, ни перенесённое
//  за верхнюю: оба входа дают один и тот же наблюдаемый исход, C-005 «Поведение»), К39 вход Б
//  (isCancelled == true — .upserted с флагом, не повод для .deleted). К39 вход А (К19,
//  поглощение по признаку (б)) уже покрыт `DedupCollisionTests.swift` — здесь не повторяется.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class SyncDeletionSemanticsTests: XCTestCase {

    /// К38: хранимая встреча, чей `start` в прошлом цикле попадал в окно; в этом цикле
    /// `fetchEvents` отдаёт ПОЛНЫЙ ответ без неё — неважно, состарилась ли она за нижнюю
    /// границу окна или источник перенёс её за верхнюю: сигнал, видимый этому уровню, один
    /// и тот же («пропала из полного ответа»), и он НИКОГДА не публикуется `.deleted` —
    /// K38 сам называет это «один и тот же исход, не два разных», поэтому оба входа не
    /// разводятся отдельными тестами. Ответ: запись остаётся в хранилище неопределённо
    /// долго, доступная через `event(id:)` (К41).
    func test_k38_meetingMissingFromFullResponseIsNeverPublishedDeletedRegardlessOfWhy() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let existingId = UUID()
        let payload = try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base)
        let event = try payload.assigningId(existingId)
        harness.meetingRepository.seed([
            MeetingRecord(
                event: event, dedupKey: DedupKey.make(from: event), status: .ready,
                sources: [
                    MeetingSource(
                        sourceConnectorId: "src-1", externalId: "evt-1", icalUid: "shared-uid",
                        lastModified: base, payload: payload
                    )
                ]
            )
        ])
        harness.connector("src-1").setFetchEvents([])   // полный ответ без этой встречи

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure)
        XCTAssertEqual(results.first?.deletedCount, 0, "пропажа из полного ответа сама по себе не считается удалением")
        XCTAssertEqual(harness.meetingRepository.storedRecords.count, 1, "запись остаётся в хранилище")
        let stillThere = try await harness.hub.event(id: existingId)
        XCTAssertNotNil(stillThere, "доступна через event(id:) — К41")
    }

    /// К39 вход Б: `isCancelled == true` в новой синхронизации. Ответ: не `.deleted` —
    /// `.upserted` с флагом.
    func test_k39_inputB_isCancelledTrueIsUpsertedWithFlagNotDeleted() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let payload = try MeetingEventPayload(
            sourceConnectorId: "src-1", externalId: "evt-1", icalUid: "shared-uid", title: "T",
            start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
            isCancelled: true, organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: base
        )
        harness.connector("src-1").setFetchEvents([payload])
        let iterator = StreamIteratorBox(harness.hub.changes())

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure)
        XCTAssertEqual(results.first?.deletedCount, 0)
        let change = await nextOrTimeout(iterator)
        guard case .upserted(let events) = change else {
            XCTFail("isCancelled==true публикуется .upserted, не .deleted — К39 вход Б")
            return
        }
        XCTAssertEqual(events.first?.isCancelled, true)
    }
}
