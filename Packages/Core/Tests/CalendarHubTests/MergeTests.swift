//  IR-126 (MEE-372/MEE-385) — слияние по снимкам источников между синхронизациями (C-005
//  v14 инв. 10/11), перенос payload в applyIncoming. Номера К — дельта перечня MEE-347 под
//  C-005 v14, на возврате у аналитика на момент этой правки (РП, 24.09 17:45 UTC) — тесты
//  названы по инвариантам контракта, не по К, до выхода дельты; переименовать после её
//  выхода не будет стоить ничего по существу — вход/ответ здесь взяты из контракта, не
//  придуманы.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
import CalendarHub

final class MergeTests: XCTestCase {

    // MARK: - Инв. 10 (C-005): identity пересчитывается всегда, даже когда содержимое заморожено

    /// К65 вход Б: источник, бывший identity встречи, пропадает (остаётся другой источник —
    /// «не .deleted»), но identity обязана пересчитаться на оставшийся источник шагом 1
    /// правила слияния (наибольший `lastModified`, тай-брейк — sourceConnectorId). Возврат
    /// РП (MEE-385, комментарий 17:10): без пересчёта `save` бросает `constraintViolation` —
    /// `sourcesIncludingOwnIdentity` (storage, инв. 31 C-010 v18) не находит identity `event`
    /// среди `remaining` и синтезировать её не вправе (синтез разрешён только при первом
    /// сохранении с одним источником).
    func test_inv10_identityRecomputedWhenDepartedSourceWasIdentity() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1", cursor: "cursor-0")])
        let connector = harness.connector("src-1")
        connector.setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: true, push: false, attendees: true, conference: true, auth: .none
        ))

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let eventId = UUID()
        let event = try MeetingEvent(
            id: eventId, sourceConnectorId: "src-1", externalId: "evt-1", icalUid: nil, title: "Original",
            start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
            isCancelled: false, organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: base
        )
        let sources = [
            MeetingSource(sourceConnectorId: "src-1", externalId: "evt-1", icalUid: nil, lastModified: base),
            MeetingSource(
                sourceConnectorId: "src-2", externalId: "evt-2", icalUid: nil,
                lastModified: base.addingTimeInterval(60)
            )
        ]
        harness.meetingRepository.seed([MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: sources)])

        connector.setFetchChanges(ChangeBatch(
            events: [], deletedExternalIds: ["evt-1"], cursor: "cursor-1", resetRequired: false
        ))

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure, "identity обязана пересчитаться, а не бросить constraintViolation")
        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1, "встреча не удалена — остался другой источник")
        XCTAssertEqual(stored.first?.event.id, eventId, "id встречи не меняется")
        XCTAssertEqual(stored.first?.event.sourceConnectorId, "src-2", "identity — оставшийся источник")
        XCTAssertEqual(stored.first?.event.externalId, "evt-2")
        XCTAssertEqual(
            stored.first?.event.title, "Original", "содержимое заморожено — снимков нет ни у одного источника"
        )
        XCTAssertEqual(stored.first?.sources.count, 1)

        let departedLookup = try await harness.meetingRepository.meeting(
            sourceConnectorId: "src-1", externalId: "evt-1"
        )
        XCTAssertNil(departedLookup, "пара ушедшего источника не должна находиться")
    }

    // MARK: - Инв. 10/11 (C-005): слияние по снимкам всех источников, сериализация по дедуп-ключу

    /// Рабочий пример РП (MEE-385, 24.09 17:45 UTC): A(lm=3, nil), B(lm=2, «X»), C(lm=1, «Y»)
    /// → «X». Три источника с общим дедуп-ключом (`icalUid`) сообщают об одной встрече ОДНИМ
    /// циклом `sync()` — `TaskGroup` заводит по задаче на источник, все три параллельно
    /// сходятся на один и тот же дедуп-ключ (инв. 11 — слияние сериализуется по ключу,
    /// `mergeTail`, иначе конкурентная запись одного стёрла бы источники другого). Победитель
    /// шага 1 — A (наибольший lastModified); его `location == nil` — шаг 2 уходит к первому
    /// источнику со снимком в порядке возрастания `sourceConnectorId` среди остальных — это
    /// B («X»), не C.
    func test_inv10_inv11_threeSourcesConcurrentMergeMatchesRPWorkedExample() async throws {
        let harness = Harness(sourceIds: ["A", "B", "C"])
        harness.connectorRepository.seed(["A", "B", "C"].map { Harness.record(id: $0) })
        for id in ["A", "B", "C"] {
            harness.connector(id).setInitializeResult(capabilities: ConnectorCapabilities(
                deltaSync: false, push: false, attendees: true, conference: true, auth: .none
            ))
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        harness.connector("A").setFetchEvents([
            try Self.payload(connectorId: "A", externalId: "evt-a", lastModified: base.addingTimeInterval(3))
        ])
        harness.connector("B").setFetchEvents([
            try Self.payload(
                connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(2), location: "X"
            )
        ])
        harness.connector("C").setFetchEvents([
            try Self.payload(
                connectorId: "C", externalId: "evt-c", lastModified: base.addingTimeInterval(1), location: "Y"
            )
        ])

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertTrue(results.allSatisfy { $0.failure == nil }, "ни один из трёх источников не должен отказать")
        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1, "общий дедуп-ключ — одна встреча, не три")
        XCTAssertEqual(stored.first?.sources.count, 3, "инв. 11 — ни один из трёх источников не потерян")
        XCTAssertEqual(stored.first?.event.sourceConnectorId, "A", "identity — наибольший lastModified")
        XCTAssertEqual(stored.first?.event.location, "X", "рабочий пример РП: A(nil) -> первый непустой B -> X")
    }

    /// Перенос снимков между циклами (инв. 10): цикл, в котором сообщил только B, не трогает
    /// снимок A — A переносится дословно из уже сохранённого состояния (`sources.filter`
    /// в `mergeIncoming`), не пересобирается заново со значением `payload == nil`.
    func test_inv10_unreportingSourceKeepsCarriedOverSnapshot() async throws {
        let harness = Harness(sourceIds: ["A", "B"])
        harness.connectorRepository.seed(["A", "B"].map { Harness.record(id: $0) })
        for id in ["A", "B"] {
            harness.connector(id).setInitializeResult(capabilities: ConnectorCapabilities(
                deltaSync: false, push: false, attendees: true, conference: true, auth: .none
            ))
        }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        harness.connector("A").setFetchEvents([
            try Self.payload(
                connectorId: "A", externalId: "evt-a", lastModified: base.addingTimeInterval(1), location: "A1"
            )
        ])
        harness.connector("B").setFetchEvents([
            try Self.payload(
                connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(2), location: "B1"
            )
        ])
        _ = await harness.hub.sync(trigger: .manual)

        // Второй цикл: A больше не сообщает (например, событие вне окна коннектора) — B обновился.
        harness.connector("A").setFetchEvents([])
        harness.connector("B").setFetchEvents([
            try Self.payload(
                connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(3), location: "B2"
            )
        ])
        _ = await harness.hub.sync(trigger: .manual)

        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.sources.count, 2, "A не сообщил во втором цикле, но его источник не потерян")
        let snapshotA = stored.first?.sources.first { $0.sourceConnectorId == "A" }?.payload
        XCTAssertEqual(snapshotA?.location, "A1", "снимок A перенесён дословно, не тронут вторым циклом")
        let snapshotB = stored.first?.sources.first { $0.sourceConnectorId == "B" }?.payload
        XCTAssertEqual(snapshotB?.location, "B2", "снимок B обновлён свежим payload")
        XCTAssertEqual(stored.first?.event.sourceConnectorId, "B", "identity — теперь B, его lastModified больше")
        XCTAssertEqual(stored.first?.event.location, "B2", "содержимое перечитано по новому победителю")
    }

    // MARK: - Оснастка

    private static func payload(
        connectorId: String, externalId: String, lastModified: Date, location: String? = nil
    ) throws -> MeetingEventPayload {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        return try MeetingEventPayload(
            sourceConnectorId: connectorId, externalId: externalId, icalUid: "shared-uid", title: "T",
            start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
            isCancelled: false, organizer: nil, attendees: [], location: location, bodyText: nil,
            conference: nil, lastModified: lastModified
        )
    }
}
