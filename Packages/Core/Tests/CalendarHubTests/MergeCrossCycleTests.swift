//  IR-126 (MEE-372/MEE-385) — слияние по снимкам источников между синхронизациями (C-005
//  v14 инв. 10/11), продолжение `MergeTests.swift`: тесты, добавленные и переписанные
//  возвратом РП (приёмка #105, 18:25 UTC, п. 3).
//
//  Разнесено на отдельный файл от `MergeTests.swift` — SwiftLint `file_length` считает
//  каждый файл отдельно (тот же приём, что развёл `CalendarPortImplSync.swift`/
//  `CalendarPortImplMerge.swift`): семь тестов возврата в одном файле вышли бы за лимит.
//  Оснастка (`mergeTestPayload`, `mergeTestAttendee`) — общая, `TestSupport.swift`.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import CalendarHub

final class MergeCrossCycleTests: XCTestCase {

    // MARK: - Инв. 10: пример IR-126 через последовательные (не одновременные) циклы

    /// Возврат РП (приёмка #105, п. 3): пример IR-126 (A/B/C, порядок C, A, B), но не одним
    /// циклом (как `MergeTests.test_inv10_inv11_threeSourcesConcurrentMergeMatchesRPWorkedExample`),
    /// а ТРЕМЯ ПОСЛЕДОВАТЕЛЬНЫМИ `sync()` — в каждом сообщает РОВНО один источник, остальные
    /// два возвращают пустой пакет (частичный вход). Хост, игнорирующий перенесённые между
    /// циклами снимки (инв. 10) или не делающий честный шаг 2 (первый непустой скаляр среди
    /// ОСТАЛЬНЫХ источников, не только у победителя identity), давал бы `nil` — сам
    /// победитель identity (A) `location` не несёт. Верный результат — тот же «X», что и в
    /// одноцикловом примере, потому что снимки C (цикл 1) и A (цикл 2) обязаны пережить
    /// циклы, где сообщает не их источник.
    func test_ir126_sequentialCyclesInOrder_C_A_B_matchRPWorkedExample() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A", "B", "C"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Цикл 1: сообщает только C.
        harness.connector("C").setFetchEvents([
            try mergeTestPayload(
                connectorId: "C", externalId: "evt-c", lastModified: base.addingTimeInterval(1), location: "Y"
            )
        ])
        harness.connector("A").setFetchEvents([])
        harness.connector("B").setFetchEvents([])
        _ = await harness.hub.sync(trigger: .manual)

        // Цикл 2: сообщает только A — снимок C обязан пережить цикл, где C молчит.
        harness.connector("C").setFetchEvents([])
        harness.connector("A").setFetchEvents([
            try mergeTestPayload(connectorId: "A", externalId: "evt-a", lastModified: base.addingTimeInterval(3))
        ])
        _ = await harness.hub.sync(trigger: .manual)

        // Цикл 3: сообщает только B — снимки A и C обязаны пережить и этот цикл тоже.
        harness.connector("A").setFetchEvents([])
        harness.connector("B").setFetchEvents([
            try mergeTestPayload(
                connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(2), location: "X"
            )
        ])
        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertTrue(results.allSatisfy { $0.failure == nil })
        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1, "общий дедуп-ключ — одна встреча за все три цикла")
        XCTAssertEqual(stored.first?.sources.count, 3, "снимки всех трёх источников пережили все три цикла")
        XCTAssertEqual(
            stored.first?.event.sourceConnectorId, "A",
            "identity — наибольший lastModified, хотя A не сообщал в последнем цикле"
        )
        XCTAssertEqual(
            stored.first?.event.location, "X",
            "хост, теряющий снимки между циклами, дал бы nil (A.location == nil сам по себе) — верный ответ X"
        )
    }

    /// Перенос снимков между циклами (инв. 10): цикл, в котором сообщил только B, не трогает
    /// снимок A — A переносится дословно из уже сохранённого состояния (`sources.filter`
    /// в `mergeIncoming`), не пересобирается заново со значением `payload == nil`.
    ///
    /// Возврат РП (приёмка #105, п. 3): раньше B был содержательным победителем В ОБОИХ
    /// циклах САМ ПО СЕБЕ (его `location` всегда непуст) — перенесённый снимок A ни на что
    /// не влиял, и сломанный перенос снимков этот тест бы не поймал. Во втором цикле у B
    /// `location == nil` — итоговое значение обязано прийти от перенесённого снимка A.
    func test_inv10_unreportingSourceKeepsCarriedOverSnapshot() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A", "B"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        harness.connector("A").setFetchEvents([
            try mergeTestPayload(
                connectorId: "A", externalId: "evt-a", lastModified: base.addingTimeInterval(1), location: "A1"
            )
        ])
        harness.connector("B").setFetchEvents([
            try mergeTestPayload(
                connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(2), location: "B1"
            )
        ])
        _ = await harness.hub.sync(trigger: .manual)

        // Второй цикл: A больше не сообщает; B обновился, но БЕЗ location — итог обязан
        // прийти от перенесённого снимка A, не от B.
        harness.connector("A").setFetchEvents([])
        harness.connector("B").setFetchEvents([
            try mergeTestPayload(
                connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(3), location: nil
            )
        ])
        _ = await harness.hub.sync(trigger: .manual)

        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.sources.count, 2, "A не сообщил во втором цикле, но его источник не потерян")
        let snapshotA = stored.first?.sources.first { $0.sourceConnectorId == "A" }?.payload
        XCTAssertEqual(snapshotA?.location, "A1", "снимок A перенесён дословно, не тронут вторым циклом")
        let snapshotB = stored.first?.sources.first { $0.sourceConnectorId == "B" }?.payload
        XCTAssertNil(snapshotB?.location, "снимок B обновлён свежим payload (тоже дословно, включая nil)")
        XCTAssertEqual(stored.first?.event.sourceConnectorId, "B", "identity — теперь B, его lastModified больше")
        XCTAssertEqual(
            stored.first?.event.location, "A1",
            "B — содержательный победитель, но его снимок location == nil — шаг 2 уходит к перенесённому A"
        )
    }

    // MARK: - Шаг 3 (C-005): объединение attendees

    /// Шаг 3 правила слияния: содержательный победитель (A, наибольший lastModified) даёт
    /// свой список первым, остальные источники (B, не победитель) добавляют СВОИХ участников
    /// — по email побеждает первая встреченная запись (та, что уже добавлена от победителя),
    /// участник без email добавляется, только если его `name` ещё не встречалось.
    func test_step3_attendeesUnionFromNonWinnerDedupedByEmailAndName() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A", "B"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        harness.connector("A").setFetchEvents([
            try mergeTestPayload(
                connectorId: "A", externalId: "evt-a", lastModified: base.addingTimeInterval(2),
                attendees: [
                    try mergeTestAttendee(name: "Иван", email: "ivan@example.com"),
                    try mergeTestAttendee(name: "Мария", email: nil)
                ]
            )
        ])
        harness.connector("B").setFetchEvents([
            try mergeTestPayload(
                connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(1),
                attendees: [
                    try mergeTestAttendee(name: "Пётр", email: "petr@example.com"),
                    try mergeTestAttendee(name: "Мария", email: nil),
                    try mergeTestAttendee(name: "Иван другой", email: "ivan@example.com")
                ]
            )
        ])

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertTrue(results.allSatisfy { $0.failure == nil })
        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1)
        let attendees = stored.first?.event.attendees ?? []
        XCTAssertEqual(
            attendees.count, 3,
            "Иван (по email, от победителя A) + Мария (без email, по имени, от A) + Пётр (новый, от B) — " +
                "дубликат «Иван другой» (тот же email) от B отброшен"
        )
        let ivan = attendees.first { $0.person.email == "ivan@example.com" }
        XCTAssertEqual(ivan?.person.name, "Иван", "email совпал — побеждает запись победителя A, не B")
        XCTAssertTrue(attendees.contains { $0.person.name == "Пётр" }, "участник B без конфликта добавлен")
        XCTAssertEqual(attendees.filter { $0.person.name == "Мария" }.count, 1, "Мария без email не задублирована")
    }

    // MARK: - Отказ источника в цикле не трогает уже сохранённые снимки

    /// Возврат РП (приёмка #105, п. 3): `fetchEvents` источника A бросает ошибку — его
    /// собственный цикл синхронизации обязан отказать (К13), но НИ ОДИН уже сохранённый
    /// снимок (ни его собственный, ни снимок B) не вправе быть тронут — `applyIncoming`
    /// вообще не вызывается для отказавшего источника этим циклом (отказ происходит ДО
    /// первого обращения к `meetingRepository`).
    func test_inv10_sourceFailureInCycleKeepsOtherSourcesSnapshotsIntact() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A", "B"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let payloadA = try mergeTestPayload(
            connectorId: "A", externalId: "evt-a", lastModified: base, location: "A1"
        )
        let payloadB = try mergeTestPayload(
            connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(1), location: "B1"
        )
        let event = try MeetingEvent(
            id: UUID(), sourceConnectorId: "B", externalId: "evt-b", icalUid: "shared-uid", title: "T",
            start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false, isCancelled: false,
            organizer: nil, attendees: [], location: "B1", bodyText: nil, conference: nil,
            lastModified: base.addingTimeInterval(1)
        )
        let sources = [
            MeetingSource(
                sourceConnectorId: "A", externalId: "evt-a", icalUid: "shared-uid", lastModified: base,
                payload: payloadA
            ),
            MeetingSource(
                sourceConnectorId: "B", externalId: "evt-b", icalUid: "shared-uid",
                lastModified: base.addingTimeInterval(1), payload: payloadB
            )
        ]
        harness.meetingRepository.seed([
            MeetingRecord(event: event, dedupKey: DedupKey.make(from: event), status: .ready, sources: sources)
        ])

        harness.connector("A").fail(.fetchEvents, with: .upstreamUnavailable(message: "boom"))
        harness.connector("B").setFetchEvents([])

        let results = await harness.hub.sync(trigger: .manual)

        let failedA = results.first { $0.sourceId == CalendarSourceId(rawValue: "A") }
        XCTAssertNotNil(failedA?.failure, "A обязан отказать этим циклом")
        let okB = results.first { $0.sourceId == CalendarSourceId(rawValue: "B") }
        XCTAssertNil(okB?.failure, "отказ A не задевает цикл B")

        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.sources.count, 2, "отказ A не удаляет ни его, ни чужой источник")
        let snapshotA = stored.first?.sources.first { $0.sourceConnectorId == "A" }?.payload
        XCTAssertEqual(snapshotA?.location, "A1", "снимок A цел — его цикл не дошёл до meetingRepository вовсе")
        let snapshotB = stored.first?.sources.first { $0.sourceConnectorId == "B" }?.payload
        XCTAssertEqual(snapshotB?.location, "B1", "B ничего нового не сообщил (пустой пакет) — снимок тоже цел")
    }
}
