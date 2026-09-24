//  Продолжение `MergeTests.swift` — три пробела, названные возвратом РП (24.09, приёмка #115,
//  комментарий на слиянии): К65 вход А (не имел теста вовсе — покрыт был только вход Б/В,
//  многоисточниковые), К76 (частичный вход между циклами, дословный вектор IR-126) и К78
//  (победитель шага 1 без снимка). Вынесено отдельным файлом той же причиной, что развела
//  `CalendarPortImplSync.swift`/`CalendarPortImplMerge.swift`: SwiftLint `file_length`/
//  `type_body_length` считают каждое расширение типа отдельно.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

extension MergeTests {

    /// К65 вход А (перечень MEE-347, группа Ж): `deletedExternalIds` называет пару у записи с
    /// ОДНИМ источником → `meeting(sourceConnectorId:externalId:)` находит её, запись удаляется
    /// целиком, публикуется `.deleted`. Не имел теста вовсе (возврат РП, 24.09, приёмка #115):
    /// вход Б/В (многоисточниковые) уже были покрыты `test_k65_input{B,V}_*`, но однoисточниковый
    /// случай, для которого К65 изначально и заведён, — нет.
    func test_k65_inputA_deletedExternalIdsSingleSourceDeletesMeetingEntirely() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"], deltaSync: true, cursor: "cursor-0")
        let connector = harness.connector("src-1")
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let eventId = UUID()
        let payload = try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base)
        let event = try MeetingEvent(
            id: eventId, sourceConnectorId: "src-1", externalId: "evt-1", icalUid: "shared-uid", title: "T",
            start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false, isCancelled: false,
            organizer: nil, attendees: [], location: nil, bodyText: nil, conference: nil, lastModified: base
        )
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

        connector.setFetchChanges(ChangeBatch(
            events: [], deletedExternalIds: ["evt-1"], cursor: "cursor-1", resetRequired: false
        ))

        let stream = harness.hub.changes()
        let iterator = StreamIteratorBox(stream)

        let results = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(results.first?.failure)

        XCTAssertTrue(
            harness.meetingRepository.storedRecords.isEmpty, "единственный источник ушёл — запись удалена целиком"
        )

        let change = await nextOrTimeout(iterator)
        guard case .deleted(let ids) = change else {
            XCTFail(".deleted обязан публиковаться, когда единственный источник записи уходит")
            return
        }
        XCTAssertEqual(ids, [eventId])
    }

    /// К76 (перечень MEE-347, дельта под C-005 v14, группа М) — дословный вектор перечня, не
    /// приближение (`test_k76_threeSourcesConcurrentMergeMatchesRPWorkedExample`/
    /// `test_k76_sequentialCyclesInOrder_C_A_B_matchRPWorkedExample` рядом покрывают его только
    /// частично, см. их докстринги). Первый цикл — ОДНО совместное слияние трёх источников:
    /// a-conn (lm=3, location=nil, attendees=[Alice]), b-conn (lm=2, «X», [Bob]),
    /// c-conn (lm=1, «Y», [Carol]) → победитель a-conn, шаг 2 → «X» (от b-conn), attendees =
    /// {Alice, Bob, Carol}. Второй цикл — сообщает ТОЛЬКО c-conn (новый lm=2, всё ещё < 3 —
    /// победитель не меняется; новый location=«Z»; новые attendees=[Carol, Dave]); a-conn и
    /// b-conn молчат — их снимки первого цикла обязаны перенестись (инв. 10). Ожидаемый
    /// результат: победитель по-прежнему a-conn; location остаётся «X» (из перенесённого
    /// снимка b-conn, не «Z» от c-conn); attendees = {Alice, Bob, Carol, Dave} — объединение с
    /// attendees a-conn, не только итог одного слияния c-conn.
    func test_k76_partialSecondCycleCarriesOverSnapshotsFromSilentSources() async throws {
        let harness = Harness.mergeReady(sourceIds: ["a-conn", "b-conn", "c-conn"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        harness.connector("a-conn").setFetchEvents([
            try mergeTestPayload(
                connectorId: "a-conn", externalId: "evt-a", lastModified: base.addingTimeInterval(3),
                attendees: [try mergeTestAttendee(name: "Alice", email: "alice@example.com")]
            )
        ])
        harness.connector("b-conn").setFetchEvents([
            try mergeTestPayload(
                connectorId: "b-conn", externalId: "evt-b", lastModified: base.addingTimeInterval(2),
                location: "X", attendees: [try mergeTestAttendee(name: "Bob", email: "bob@example.com")]
            )
        ])
        harness.connector("c-conn").setFetchEvents([
            try mergeTestPayload(
                connectorId: "c-conn", externalId: "evt-c", lastModified: base.addingTimeInterval(1),
                location: "Y", attendees: [try mergeTestAttendee(name: "Carol", email: "carol@example.com")]
            )
        ])
        let firstResults = await harness.hub.sync(trigger: .manual)
        XCTAssertTrue(firstResults.allSatisfy { $0.failure == nil })
        let firstStored = try XCTUnwrap(harness.meetingRepository.storedRecords.first)
        XCTAssertEqual(firstStored.event.sourceConnectorId, "a-conn", "победитель шага 1 первого цикла — a-conn")
        XCTAssertEqual(
            firstStored.event.location, "X", "шаг 2: a-conn(nil) -> первый непустой среди остальных -> b-conn"
        )
        XCTAssertEqual(Set(firstStored.event.attendees.map(\.person.name)), ["Alice", "Bob", "Carol"])

        // Второй цикл: сообщает только c-conn — снимки a-conn и b-conn обязаны перенестись.
        harness.connector("a-conn").setFetchEvents([])
        harness.connector("b-conn").setFetchEvents([])
        harness.connector("c-conn").setFetchEvents([
            try mergeTestPayload(
                connectorId: "c-conn", externalId: "evt-c", lastModified: base.addingTimeInterval(2),
                location: "Z",
                attendees: [
                    try mergeTestAttendee(name: "Carol", email: "carol@example.com"),
                    try mergeTestAttendee(name: "Dave", email: "dave@example.com")
                ]
            )
        ])
        let secondResults = await harness.hub.sync(trigger: .manual)
        XCTAssertTrue(secondResults.allSatisfy { $0.failure == nil })

        let stored = try XCTUnwrap(harness.meetingRepository.storedRecords.first)
        XCTAssertEqual(
            stored.event.sourceConnectorId, "a-conn", "a-conn остаётся победителем — его lm=3 всё ещё наибольший"
        )
        XCTAssertEqual(stored.event.location, "X", "снимок b-conn перенесён из первого цикла — не «Z» от c-conn")
        XCTAssertEqual(
            Set(stored.event.attendees.map(\.person.name)), ["Alice", "Bob", "Carol", "Dave"],
            "объединение с attendees a-conn (перенесённых), не только итог одного слияния c-conn"
        )
    }

    /// К78 (перечень MEE-347, дельта под C-005 v14, группа М): победитель шага 1 (наибольший
    /// `lastModified`) оказывается БЕЗ снимка (`payload == nil`, переходное состояние) — шаг 2
    /// обязан считать его скалярный вклад ОТСУТСТВУЮЩИМ и перейти к первому источнику СО
    /// снимком в порядке возрастания `sourceConnectorId`, не просто к следующему по
    /// `lastModified`. Не имел покрытия вовсе (возврат РП, 24.09, MEE-361, приёмка дельты
    /// b943cc7e, находка 10). z-conn (lm наибольший, без снимка) уже числится identity вместе с
    /// b-conn (снимок «Room 2») — a-conn (снимок «Room 1») присоединяется новым `applyIncoming`,
    /// не меняя победителя (его lm меньше обоих).
    func test_k78_winnerWithoutSnapshotSkipsToFirstSnapshotHolderByAscendingSourceId() async throws {
        let harness = Harness.mergeReady(sourceIds: ["a-conn", "b-conn", "z-conn"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let eventId = UUID()
        let payloadB = try mergeTestPayload(
            connectorId: "b-conn", externalId: "evt-b", lastModified: base.addingTimeInterval(1), location: "Room 2"
        )
        let event = try MeetingEvent(
            id: eventId, sourceConnectorId: "z-conn", externalId: "evt-z", icalUid: "shared-uid", title: "T",
            start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false, isCancelled: false,
            organizer: nil, attendees: [], location: nil, bodyText: nil, conference: nil,
            lastModified: base.addingTimeInterval(10)
        )
        harness.meetingRepository.seed([
            MeetingRecord(
                event: event, dedupKey: DedupKey.make(from: event), status: .ready,
                sources: [
                    MeetingSource(
                        sourceConnectorId: "z-conn", externalId: "evt-z", icalUid: "shared-uid",
                        lastModified: base.addingTimeInterval(10), payload: nil
                    ),
                    MeetingSource(
                        sourceConnectorId: "b-conn", externalId: "evt-b", icalUid: "shared-uid",
                        lastModified: base.addingTimeInterval(1), payload: payloadB
                    )
                ]
            )
        ])

        let payloadA = try mergeTestPayload(
            connectorId: "a-conn", externalId: "evt-a", lastModified: base, location: "Room 1"
        )
        _ = try await harness.hub.applyIncoming(payload: payloadA)

        let stored = try XCTUnwrap(harness.meetingRepository.storedRecords.first)
        XCTAssertEqual(stored.sources.count, 3, "все три источника присутствуют после applyIncoming")
        XCTAssertEqual(
            stored.event.sourceConnectorId, "z-conn", "identity/победитель шага 1 — z-conn, наибольший lastModified"
        )
        XCTAssertEqual(
            stored.event.location, "Room 1",
            "победитель без снимка пропущен шагом 2 — переход к первому снимко-держателю по возрастанию " +
                "sourceConnectorId (a-conn), не b-conn"
        )
    }
}
