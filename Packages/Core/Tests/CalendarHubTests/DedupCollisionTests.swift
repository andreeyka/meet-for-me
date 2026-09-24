//  К19 (перечень MEE-347, C-005 v14 правило слияния п.4) — коллизия двух кандидатов:
//  признак (а) и признак (б) (по паре ТОГО ЖЕ payload'а) указывают на РАЗНЫЕ существующие
//  записи. Отдельный файл — новая логика (`CalendarPortImplMerge.swift`, `mergeIncoming`),
//  не тест на уже существующее поведение (в отличие от К17/К18 рядом).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class DedupCollisionTests: XCTestCase {

    /// Признак (а) (по вычисленному `DedupKey` входящего payload'а) находит X, признак (б)
    /// (по паре ТОГО ЖЕ payload'а) — Y, X ≠ Y: два разных существующих кандидата. Ответ:
    /// побеждает запись с лексикографически меньшим `id.uuidString`; источники проигравшей
    /// переходят победителю, её `id` публикуется `.deleted` (К39 вход А).
    ///
    /// СТРОКА (буквальное прочтение, возврат РП 24.09 22:57 UTC — см. докстринг
    /// `mergeIncoming`, `CalendarPortImplMerge.swift`): X и Y здесь заведены СЕМАНТИЧЕСКИ
    /// не связанными (X с `icalUid`, Y без) — единственный проверяемый здесь код-путь
    /// коллизии тот, где входящий payload сам указывает на Y своей парой
    /// (`sourceConnectorId`/`externalId`), но вычисляет `DedupKey`, совпадающий с уже
    /// сохранённым `dedupKey` X.
    func test_k19_twoCandidatesByPairMergeLexicographicallySmallerWins() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        let sharedStart = Date(timeIntervalSince1970: 1_700_000_000)

        let idX = UUID()
        try seedCollisionCandidateX(harness, id: idX, start: sharedStart)
        let idY = UUID()
        try seedCollisionCandidateY(harness, id: idY, start: sharedStart.addingTimeInterval(3_600))

        // Входящий payload сообщает пару Y (src-2/evt-2), но с icalUid и стартом X — признак
        // (а) находит X (по dedupKey), признак (б) — Y (по паре этого же payload'а).
        let stream = harness.hub.changes()
        let iterator = StreamIteratorBox(stream)
        let colliding = try mergeTestPayload(
            connectorId: "src-2", externalId: "evt-2", lastModified: sharedStart.addingTimeInterval(20),
            location: "Room-New"
        )
        let saved = try await harness.hub.applyIncoming(payload: colliding)
        XCTAssertTrue(saved)

        let winnerId = idX.uuidString < idY.uuidString ? idX : idY
        let loserId = idX.uuidString < idY.uuidString ? idY : idX

        let change = await nextOrTimeout(iterator)
        guard case .deleted(let ids) = change else {
            XCTFail(".deleted обязан публиковаться для поглощённой (проигравшей) записи — К39 вход А")
            return
        }
        XCTAssertEqual(ids, [loserId])

        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1, "проигравшая запись поглощена — осталась одна")
        XCTAssertEqual(stored.first?.event.id, winnerId, "побеждает лексикографически меньший id.uuidString")
        XCTAssertEqual(stored.first?.sources.count, 2, "источники проигравшей перешли победителю")
        XCTAssertTrue(
            stored.first?.sources.contains { $0.sourceConnectorId == "src-1" && $0.externalId == "evt-1" } ?? false,
            "источник X сохранён"
        )
        XCTAssertTrue(
            stored.first?.sources.contains { $0.sourceConnectorId == "src-2" && $0.externalId == "evt-2" } ?? false,
            "источник Y (обновлённый входящим payload'ом) сохранён"
        )
    }
}

/// Кандидат X — единственный источник src-1/evt-1, с `icalUid` "shared-uid" (совпадёт с
/// признаком (а) входящего payload'а теста). Вынесено свободной функцией — SwiftLint
/// `function_body_length` (предел 50 строк) считает только код самого теста.
private func seedCollisionCandidateX(_ harness: Harness, id: UUID, start: Date) throws {
    let payload = try mergeTestPayload(
        connectorId: "src-1", externalId: "evt-1", lastModified: start, location: "Room-X"
    )
    let event = try MeetingEvent(
        id: id, sourceConnectorId: "src-1", externalId: "evt-1", icalUid: "shared-uid", title: "T",
        start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
        isCancelled: false, organizer: nil, attendees: [], location: "Room-X", bodyText: nil, conference: nil,
        lastModified: start
    )
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
}

/// Кандидат Y — единственный источник src-2/evt-2, БЕЗ `icalUid` (`dedupKey` — `nil`),
/// семантически не связан с X до входящего payload'а теста.
private func seedCollisionCandidateY(_ harness: Harness, id: UUID, start: Date) throws {
    let payload = try MeetingEventPayload(
        sourceConnectorId: "src-2", externalId: "evt-2", icalUid: nil, title: "T",
        start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
        isCancelled: false, organizer: nil, attendees: [], location: "Room-Y", bodyText: nil, conference: nil,
        lastModified: start
    )
    let event = try payload.assigningId(id)
    harness.meetingRepository.seed([
        MeetingRecord(
            event: event, dedupKey: DedupKey.make(from: event), status: .ready,
            sources: [
                MeetingSource(
                    sourceConnectorId: "src-2", externalId: "evt-2", icalUid: nil, lastModified: start, payload: payload
                )
            ]
        )
    ])
}
