//  Группа Г (К30-К43) плана MEE-361, файл `SyncTests.swift` — эта правка (МЕЕ-362 ч.2)
//  покрывает здесь ТОЛЬКО К40-К41 (постановка называет их явно, остальные К30-39/42-43 в
//  списке нет). `events(from:to:)`/`event(id:)` читают уже слитые встречи напрямую из
//  `MeetingRepository` — синхронизация (`sync`) в дело не входит, `Harness` заводится без
//  единого источника (`sourceIds: []`).
//
//  ЧТО ЭТА ПРАВКА НЕ ПОКРЫВАЕТ ЗДЕСЬ, ЧЕСТНО: К30-К39, К42-К43 — остаются следующей части.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import CalendarHub

final class SyncTests: XCTestCase {

    // MARK: - К40 (инв. 6 — сортировка по start, затем по id на ничью; окно вне синхронизированного пусто)

    func test_k40_eventsSortedByStartThenByIdOnTie_emptyOutsideWindow() async throws {
        HangDiagnostics.checkpoint("SyncTests.test_k40_eventsSortedByStartThenByIdOnTie_emptyOutsideWindow START")
        let harness = Harness(sourceIds: [])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let recordEarly = try Self.makeRecord(
            id: "11111111-1111-4111-8111-111111111111", start: base, externalId: "evt-early"
        )
        let recordMiddle = try Self.makeRecord(
            id: "22222222-2222-4222-8222-222222222222", start: base.addingTimeInterval(3_600), externalId: "evt-middle"
        )
        let recordOutside = try Self.makeRecord(
            id: "33333333-3333-4333-8333-333333333333",
            start: base.addingTimeInterval(999_999), externalId: "evt-outside"
        )
        // Порядок seed — произвольный, не по возрастанию start: результат обязан сортироваться
        // самим методом, не унаследовать порядок хранения.
        harness.meetingRepository.seed([recordOutside, recordMiddle, recordEarly])

        // Вход А: окно захватывает два из трёх, отсортированы по возрастанию start.
        let events = try await harness.hub.events(from: base, to: base.addingTimeInterval(3_601))
        XCTAssertEqual(events.map(\.id), [recordEarly.event.id, recordMiddle.event.id])

        // Окно вне всего, что когда-либо синхронизировал источник — [], не ошибка.
        let outsideEvents = try await harness.hub.events(
            from: base.addingTimeInterval(10_000_000), to: base.addingTimeInterval(10_100_000)
        )
        XCTAssertEqual(outsideEvents, [])

        // Вход Б (ничья по start, возврат РП п. 11): равный start, разные id — порядок по id
        // лексикографически; записи поданы в заведомо ОБРАТНОМ порядке хранения (B, затем A),
        // чтобы совпадение с порядком вставки не маскировало отсутствие реальной сортировки.
        let tieHarness = Harness(sourceIds: [])
        let tieA = try Self.makeRecord(
            id: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", start: base, externalId: "evt-tie-a"
        )
        let tieB = try Self.makeRecord(
            id: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB", start: base, externalId: "evt-tie-b"
        )
        tieHarness.meetingRepository.seed([tieB, tieA])

        let tieEvents = try await tieHarness.hub.events(from: base, to: base.addingTimeInterval(1))
        XCTAssertEqual(tieEvents.map(\.id), [tieA.event.id, tieB.event.id])
    }

    // MARK: - К41 (event(id:))

    func test_k41_eventByIdOrNilForUnknown() async throws {
        HangDiagnostics.checkpoint("SyncTests.test_k41_eventByIdOrNilForUnknown START")
        let harness = Harness(sourceIds: [])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try Self.makeRecord(
            id: "44444444-4444-4444-8444-444444444444", start: base, externalId: "evt-known"
        )
        harness.meetingRepository.seed([record])

        let found = try await harness.hub.event(id: record.event.id)
        XCTAssertEqual(found, record.event)

        let missing = try await harness.hub.event(id: UUID())
        XCTAssertNil(missing, "случайный, никогда не встречавшийся UUID — nil, не ошибка")
    }

    // MARK: - Оснастка

    private static func makeRecord(id: String, start: Date, externalId: String) throws -> MeetingRecord {
        guard let uuid = UUID(uuidString: id) else { preconditionFailure("невалидный литерал UUID: \(id)") }
        let event = try MeetingEvent(
            id: uuid, sourceConnectorId: "eventkit", externalId: externalId, icalUid: nil, title: "T",
            start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
            isCancelled: false, organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: start
        )
        return MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: [])
    }
}
