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
}
