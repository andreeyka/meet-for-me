//  Продолжение `DedupAndMergeTests.swift` (К15-К29, группа В плана MEE-361) — вынесено
//  отдельным файлом той же причиной, что развела `CalendarPortImplSync.swift`/
//  `CalendarPortImplMerge.swift`: SwiftLint `type_body_length` считает КАЖДОЕ расширение
//  типа отдельно, а не суммой по всем файлам модуля.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

extension DedupAndMergeTests {

    /// Слитая запись первого цикла (max А,Б — А) получает во втором цикле третье событие В
    /// с БОЛЬШИМ `lastModified`, чем текущий максимум → результат — max(А,Б,В), не только
    /// max последней пары (А обязан остаться участником сравнения, не быть забытым).
    func test_k23_lastModifiedIsMaxAcrossAllNotPairwise() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2", "src-3"])
        let base = Date(timeIntervalSince1970: 1_700_000_100)

        harness.connector("src-1").setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base)
        ])
        harness.connector("src-2").setFetchEvents([
            try mergeTestPayload(connectorId: "src-2", externalId: "evt-2", lastModified: base.addingTimeInterval(-50))
        ])
        let firstResults = await harness.hub.sync(trigger: .manual)
        for result in firstResults { XCTAssertNil(result.failure) }
        let firstStored = try XCTUnwrap(harness.meetingRepository.storedRecords.first)
        XCTAssertEqual(firstStored.event.lastModified, base, "победитель первого цикла — А (t=base)")

        harness.connector("src-1").setFetchEvents([])
        harness.connector("src-2").setFetchEvents([])
        harness.connector("src-3").setFetchEvents([
            try mergeTestPayload(connectorId: "src-3", externalId: "evt-3", lastModified: base.addingTimeInterval(100))
        ])
        let secondResults = await harness.hub.sync(trigger: .manual)
        for result in secondResults { XCTAssertNil(result.failure) }

        let secondStored = try XCTUnwrap(harness.meetingRepository.storedRecords.first)
        XCTAssertEqual(
            secondStored.event.lastModified, base.addingTimeInterval(100),
            "результат — max(А,Б,В), не только max последней пары"
        )
        XCTAssertEqual(secondStored.sources.count, 3, "все три источника сохранены как sources")
    }

    /// Слияние двух источников (сценарий К21) — `MeetingRecord.sources` обязана нести оба
    /// `MeetingSource`, ни один не потерян (в отличие от `event`, где остаётся только
    /// побеждающее содержимое).
    func test_k24_sourcesPreservedAfterMerge() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        let base = Date(timeIntervalSince1970: 1_700_000_100)

        harness.connector("src-1").setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base.addingTimeInterval(60))
        ])
        harness.connector("src-2").setFetchEvents([
            try mergeTestPayload(connectorId: "src-2", externalId: "evt-2", lastModified: base)
        ])
        let results = await harness.hub.sync(trigger: .manual)
        for result in results { XCTAssertNil(result.failure) }

        let stored = try XCTUnwrap(harness.meetingRepository.storedRecords.first)
        XCTAssertEqual(stored.sources.count, 2, "оба MeetingSource сохранены, ни один не потерян")
        XCTAssertTrue(stored.sources.contains { $0.sourceConnectorId == "src-1" && $0.externalId == "evt-1" })
        XCTAssertTrue(stored.sources.contains { $0.sourceConnectorId == "src-2" && $0.externalId == "evt-2" })
    }

    /// Общий `icalUid`, `start` расходится на 90 секунд — после округления инварианта 3
    /// (floor до минуты) 90с всегда переводят в другую минутную корзину независимо от фазы
    /// исходной секунды внутри своей минуты (90 > 60) → разные `dedupKey`, разные встречи.
    func test_k27_ninetySecondsApartDifferentMinutesDoNotMerge() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let connector = harness.connector("src-1")
        let start1 = Date(timeIntervalSince1970: 1_700_000_000)
        let start2 = start1.addingTimeInterval(90)

        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: start1, start: start1)
        ])
        let firstResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(firstResults.first?.failure)
        XCTAssertEqual(harness.meetingRepository.storedRecords.count, 1)

        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-2", lastModified: start2, start: start2)
        ])
        let secondResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(secondResults.first?.failure)

        XCTAssertEqual(
            harness.meetingRepository.storedRecords.count, 2,
            "разные минуты после округления — разные dedupKey, разные встречи"
        )
    }

    /// Три события одного ключа, все шесть перестановок подачи через `applyIncoming`
    /// напрямую (не через `sync`/ФК — сама плавность фан-аута `sync` по источникам не
    /// управляема тестом, а порядок здесь — предмет проверки) → результат совпадает
    /// побитово по всем полям содержимого (кроме `id` — тот новый на каждый ФРЕШ-харнесс,
    /// UUID первого события своего прогона, сравнивается отдельно на непустоту).
    func test_k28_mergeResultIndependentOfArrivalOrder() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_100)
        let payloadA = try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base)
        let payloadB = try mergeTestPayload(
            connectorId: "src-2", externalId: "evt-2", lastModified: base.addingTimeInterval(30)
        )
        let payloadC = try mergeTestPayload(
            connectorId: "src-3", externalId: "evt-3", lastModified: base.addingTimeInterval(60)
        )
        let permutations = [
            [payloadA, payloadB, payloadC], [payloadA, payloadC, payloadB],
            [payloadB, payloadA, payloadC], [payloadB, payloadC, payloadA],
            [payloadC, payloadA, payloadB], [payloadC, payloadB, payloadA]
        ]

        let fixedId = UUID()
        var canonicalResults: [MeetingEvent] = []
        for permutation in permutations {
            let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2", "src-3"])
            for payload in permutation {
                _ = try await harness.hub.applyIncoming(payload: payload)
            }
            let event = try XCTUnwrap(harness.meetingRepository.storedRecords.first?.event)
            canonicalResults.append(try Self.withFixedId(event, id: fixedId))
        }

        for result in canonicalResults.dropFirst() {
            XCTAssertEqual(result, canonicalResults[0], "результат слияния не должен зависеть от порядка подачи")
        }
    }

    static func withFixedId(_ event: MeetingEvent, id: UUID) throws -> MeetingEvent {
        try MeetingEvent(
            id: id, sourceConnectorId: event.sourceConnectorId, externalId: event.externalId,
            icalUid: event.icalUid, title: event.title, start: event.start, end: event.end,
            timeZone: event.timeZone, isAllDay: event.isAllDay, isCancelled: event.isCancelled,
            organizer: event.organizer, attendees: event.attendees, location: event.location,
            bodyText: event.bodyText, conference: event.conference, lastModified: event.lastModified
        )
    }

    /// `fetchEvents` отдаёт уже нормализованный `MeetingEventPayload` (новый dedupKey, нет
    /// существующей записи) → хост не переписывает НИ ОДНО поле, единственное действие —
    /// `assigningId`.
    func test_k29_hostDoesNotRewriteNormalizedFieldsOnlyAssignsId() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let connector = harness.connector("src-1")
        let lastModified = Date(timeIntervalSince1970: 1_700_000_100)
        let attendees = [try mergeTestAttendee(name: "A", email: "a@example.com")]
        let payload = try mergeTestPayload(
            connectorId: "src-1", externalId: "evt-1", lastModified: lastModified, location: "Room 1",
            attendees: attendees
        )
        connector.setFetchEvents([payload])

        let results = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(results.first?.failure)

        let event = try XCTUnwrap(harness.meetingRepository.storedRecords.first?.event)
        XCTAssertEqual(event.sourceConnectorId, payload.sourceConnectorId)
        XCTAssertEqual(event.externalId, payload.externalId)
        XCTAssertEqual(event.icalUid, payload.icalUid)
        XCTAssertEqual(event.title, payload.title)
        XCTAssertEqual(event.start, payload.start)
        XCTAssertEqual(event.end, payload.end)
        XCTAssertEqual(event.timeZone, payload.timeZone)
        XCTAssertEqual(event.isAllDay, payload.isAllDay)
        XCTAssertEqual(event.isCancelled, payload.isCancelled)
        XCTAssertEqual(event.organizer, payload.organizer)
        XCTAssertEqual(event.attendees, payload.attendees)
        XCTAssertEqual(event.location, payload.location)
        XCTAssertEqual(event.bodyText, payload.bodyText)
        XCTAssertEqual(event.conference, payload.conference)
        XCTAssertEqual(event.lastModified, payload.lastModified)
    }
}
