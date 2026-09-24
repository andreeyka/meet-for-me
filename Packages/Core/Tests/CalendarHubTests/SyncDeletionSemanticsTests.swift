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

    /// К38 вход А: хранимая встреча состарилась за НИЖНЮЮ границу окна — `start` заведомо
    /// раньше `now − 7д`. `fetchEvents` отдаёт ПОЛНЫЙ ответ без неё. Ответ: не `.deleted` —
    /// запись остаётся в хранилище, доступная через `event(id:)` (К41).
    func test_k38_inputA_meetingAgedBelowLowerWindowBoundIsNeverPublishedDeleted() async throws {
        try await Self.assertMissingFromFullResponseIsNeverDeleted(start: Date().addingTimeInterval(-30 * 24 * 3_600))
    }

    /// К38 вход Б (возврат РП, приёмка #128: прежний прогон случайно проверял только вход
    /// А — фиксированный `start = 1_700_000_000`, 2023 год, УЖЕ вне окна относительно
    /// реального `now` теста, вход Б не упражнялся вовсе): хранимая встреча с `start`,
    /// заведомо ВНУТРИ текущего окна (`now + 10д`, значит источник её «перенёс за верхнюю
    /// границу» или иначе не отдал в полном ответе). Ответ — тот же, что у входа А: К38
    /// сам называет это «один и тот же исход, не два разных» (сигнал «пропала из полного
    /// ответа» неотличим от переноса), поэтому проверка — тот же общий пролог, не
    /// отдельная ветка кода.
    func test_k38_inputB_meetingWithStartStillInsideWindowIsNeverPublishedDeleted() async throws {
        try await Self.assertMissingFromFullResponseIsNeverDeleted(start: Date().addingTimeInterval(10 * 24 * 3_600))
    }

    private static func assertMissingFromFullResponseIsNeverDeleted(
        start: Date, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let existingId = UUID()
        let payload = try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: start, start: start)
        let event = try payload.assigningId(existingId)
        harness.meetingRepository.seed([
            MeetingRecord(
                event: event, dedupKey: DedupKey.make(from: event), status: .ready,
                sources: [
                    MeetingSource(
                        sourceConnectorId: "src-1", externalId: "evt-1", icalUid: "shared-uid",
                        lastModified: start, payload: payload
                    )
                ]
            )
        ])
        harness.connector("src-1").setFetchEvents([])   // полный ответ без этой встречи

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure, file: file, line: line)
        XCTAssertEqual(
            results.first?.deletedCount, 0, "пропажа из полного ответа сама по себе не считается удалением",
            file: file, line: line
        )
        XCTAssertEqual(
            harness.meetingRepository.storedRecords.count, 1, "запись остаётся в хранилище", file: file, line: line
        )
        let stillThere = try await harness.hub.event(id: existingId)
        XCTAssertNotNil(stillThere, "доступна через event(id:) — К41", file: file, line: line)
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
