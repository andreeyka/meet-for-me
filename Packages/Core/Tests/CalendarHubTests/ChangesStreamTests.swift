//  Группа Д (К62-К63) плана MEE-361: поток `changes()` — не переигрывает известное,
//  одинаковая последовательность у нескольких подписчиков.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class ChangesStreamTests: XCTestCase {

    // MARK: - К62 (поток пуст при подписке, доходит только то, что случилось после)

    func test_k62_streamDoesNotReplayPriorStateOnlyFutureChanges() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let priorRecords = try (0..<3).map { index in
            try Self.makeRecord(start: base.addingTimeInterval(Double(index) * 60), externalId: "evt-prior-\(index)")
        }
        // Три записи уже сохранены (мимо save — вход теста, не наблюдаемый эффект) ДО подписки.
        harness.meetingRepository.seed(priorRecords)

        let stream = harness.hub.changes()
        let iterator = StreamIteratorBox(stream)

        // Четвёртое событие сохраняется через обычный sync ПОСЛЕ подписки.
        let newPayload = try MeetingEventPayload(
            sourceConnectorId: "eventkit", externalId: "evt-new", icalUid: nil, title: "New",
            start: base.addingTimeInterval(600), end: base.addingTimeInterval(1_800), timeZone: "UTC",
            isAllDay: false, isCancelled: false, organizer: nil, attendees: [], location: nil,
            bodyText: nil, conference: nil, lastModified: base.addingTimeInterval(600)
        )
        connector.setFetchEvents([newPayload])
        _ = await harness.hub.sync(trigger: .manual)

        let change = await nextOrTimeout(iterator)
        guard case .upserted(let events) = change else {
            XCTFail("ожидался .upserted, получено \(String(describing: change))")
            return
        }
        XCTAssertEqual(events.first?.externalId, "evt-new", "поток несёт только то, что случилось ПОСЛЕ подписки")

        // Начальное состояние (все четыре) читается отдельно, через events(from:to:) — не поток.
        let all = try await harness.hub.events(from: base, to: base.addingTimeInterval(3_600))
        XCTAssertEqual(all.count, 4)
    }

    // MARK: - К63 (одна публикация расходится на всех подписчиков в одном порядке)

    func test_k63_multipleSubscribersSeeSameSequence() async throws {
        let harness = Harness(sourceIds: [])
        let stream1 = harness.hub.changes()
        let stream2 = harness.hub.changes()
        let iterator1 = StreamIteratorBox(stream1)
        let iterator2 = StreamIteratorBox(stream2)

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let event1 = try Self.makeEvent(id: UUID(), start: base, externalId: "evt-1")
        let event2 = try Self.makeEvent(id: UUID(), start: base, externalId: "evt-2")
        let deletedId = UUID()

        await harness.hub.emit(.upserted([event1]))
        await harness.hub.emit(.upserted([event2]))
        await harness.hub.emit(.deleted([deletedId]))

        let expected: [CalendarChange] = [.upserted([event1]), .upserted([event2]), .deleted([deletedId])]
        let seq1 = [await nextOrTimeout(iterator1), await nextOrTimeout(iterator1), await nextOrTimeout(iterator1)]
        let seq2 = [await nextOrTimeout(iterator2), await nextOrTimeout(iterator2), await nextOrTimeout(iterator2)]

        XCTAssertEqual(seq1.count, seq1.compactMap { $0 }.count, "ни одно из трёх не nil")
        XCTAssertEqual(seq2.count, seq2.compactMap { $0 }.count, "ни одно из трёх не nil")
        XCTAssertEqual(seq1.compactMap { $0 }, expected)
        XCTAssertEqual(seq2.compactMap { $0 }, expected)
    }

    // MARK: - Оснастка

    private static func makeRecord(start: Date, externalId: String) throws -> MeetingRecord {
        let event = try makeEvent(id: UUID(), start: start, externalId: externalId)
        return MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: [])
    }

    private static func makeEvent(id: UUID, start: Date, externalId: String) throws -> MeetingEvent {
        try MeetingEvent(
            id: id, sourceConnectorId: "eventkit", externalId: externalId, icalUid: nil, title: "T",
            start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
            isCancelled: false, organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: start
        )
    }
}
