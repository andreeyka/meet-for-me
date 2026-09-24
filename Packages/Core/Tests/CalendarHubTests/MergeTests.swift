//  IR-126 (MEE-372/MEE-385) — слияние по снимкам источников между синхронизациями (C-005
//  v14 инв. 10/11), перенос payload в applyIncoming. Номера К — дельта перечня MEE-347 под
//  C-005 v14, на возврате у аналитика на момент этой правки (РП, 24.09 17:45 UTC) — тесты
//  названы по инвариантам контракта, не по К, до выхода дельты; переименовать после её
//  выхода не будет стоить ничего по существу — вход/ответ здесь взяты из контракта, не
//  придуманы.
//
//  Возврат РП (приёмка #105, 18:25 UTC) — identity/содержимое при уходе источника (п. 1) и
//  настоящее доказательство сериализации инв. 11 воротами `save` (п. 2/3), не только её
//  результата. Остальные новые тесты того возврата (IR-126 последовательными циклами,
//  attendees, отказ источника в цикле) — `MergeCrossCycleTests.swift`, той же причиной
//  разнесено, что развело `CalendarPortImplSync.swift`/`CalendarPortImplMerge.swift`:
//  SwiftLint `file_length` считает каждый файл отдельно. Общая оснастка (`mergeTestPayload`,
//  `mergeTestAttendee`, `meetingRepositorySaveCallCount`, `seedTwoSourceMeeting…`) —
//  `TestSupport.swift`, одна на оба файла.
//
//  Возврат РП (18:55 UTC, MEE-386): инв. 11 — ворота с ручным отпуском
//  (`InMemoryMeetingRepository.gate(on:)`/`release(on:)`) вместо `hang` на фиксированную
//  секунду, плюс сценарий с РАЗНЫМИ `DedupKey` на одну пару источника
//  (`test_inv11_differentDedupKeysSameSourcePairDoesNotRaceIntoConstraintViolation`);
//  `.upserted` проверен и в ветке без снимков (`test_k65_inputV_...FreezesContentRecomputesIdentityOnly`).

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class MergeTests: XCTestCase {

    // MARK: - Инв. 10 (C-005): identity пересчитывается всегда, даже когда содержимое заморожено

    /// К65 вход В (перечень MEE-347, дельта под C-005 v14, IR-126/MEE-372): источник, бывший
    /// identity встречи, пропадает (остаётся другой источник — «не .deleted»), НИ У ОДНОГО из
    /// оставшихся источников снимка нет (`raw_payload_json` у всех NULL) → содержимое (шаги
    /// 2-3) НЕ пересчитывается, событие остаётся точно таким, каким было до потери источника;
    /// identity при этом пересчитывается шагом 1 всегда — на оставшийся источник.
    ///
    /// Возврат РП (MEE-385, комментарий 17:10): без пересчёта identity `save` бросает
    /// `constraintViolation` — `sourcesIncludingOwnIdentity` (storage, инв. 31 C-010 v18) не
    /// находит identity `event` среди `remaining` и синтезировать её не вправе (синтез
    /// разрешён только при первом сохранении с одним источником).
    ///
    /// Возврат РП (24.09, MEE-361/MEE-386, «мелочи»): докстрока раньше называла этот сценарий
    /// «К65 вход Б» — расхождение с действующей (после дельты под C-005 v14) редакцией К65,
    /// где вход Б требует снимок хотя бы у ОДНОГО оставшегося источника (см. следующий тест),
    /// а этот сценарий (снимка нет ни у кого) — отдельный, новый вход В. Переименовано под
    /// действующую раскладку, логика теста не менялась.
    func test_k65_inputV_departedSourceNoRemainingSnapshotFreezesContentRecomputesIdentityOnly() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"], deltaSync: true, cursor: "cursor-0")
        let connector = harness.connector("src-1")

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let eventId = UUID()
        try seedTwoSourceMeetingNoSnapshots(harness, eventId: eventId, base: base)

        connector.setFetchChanges(ChangeBatch(
            events: [], deletedExternalIds: ["evt-1"], cursor: "cursor-1", resetRequired: false
        ))

        // Возврат РП (приёмка #105, 18:55 UTC): «.upserted в ветке без снимков» — подписка
        // ДО sync(), чтобы поймать саму публикацию, не только конечное состояние storage.
        let stream = harness.hub.changes()
        let iterator = StreamIteratorBox(stream)

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

        let change = await nextOrTimeout(iterator)
        guard case .upserted(let events) = change else {
            XCTFail(".upserted обязан публиковаться и в ветке без снимков, если identity изменилась")
            return
        }
        XCTAssertEqual(events.first?.sourceConnectorId, "src-2", "опубликованное событие несёт пересчитанную identity")
    }

    /// К65 вход Б (перечень MEE-347, дельта под C-005 v14, IR-126/MEE-372, сужен этой
    /// дельтой — раньше был единственным многоисточниковым входом на оба случая, теперь
    /// требует снимок хотя бы у ОДНОГО оставшегося источника; случай без снимка ни у кого —
    /// отдельный вход В, тест выше). A и B — ОБА со снимками. A — identity и содержимое, B —
    /// второй источник с собственным снимком. A уходит — у оставшегося B есть снимок, значит
    /// правило C-005 шагов 1-6 обязано пересчитать НЕ ТОЛЬКО identity, но и содержимое целиком
    /// (`Self.merge(sources: remaining, …)`), а не оставлять прежний текст `location`.
    ///
    /// СТРОКА (возврат РП, 24.09, MEE-361, приёмка дельты b943cc7e, п. 3): вектор перечня для
    /// этого входа называет конкретный скаляр — `eventkit-1` несёт `location`="Room 1",
    /// `graph-work-1` — nil, после пересчёта над одним `graph-work-1` `location`=nil (поле
    /// пропадает вместе с ушедшим источником). Этот тест такой вектор не строит буквально
    /// (свои условные "A"/"B", location="A" пропадает, остаётся "B") — сохраняет правило
    /// входа Б (пересчёт содержимого по снимку оставшегося источника), но не байт-в-байт
    /// значения перечня; отдельный тест на буквальный вектор («Room 1» → nil) не заведён.
    func test_k65_inputB_departedSourceRemainingSnapshotRecomputesIdentityAndContent() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"], deltaSync: true, cursor: "cursor-0")
        let connector = harness.connector("src-1")

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let eventId = UUID()
        let payloadA = try mergeTestPayload(
            connectorId: "src-1", externalId: "evt-1", lastModified: base, location: "A"
        )
        let payloadB = try mergeTestPayload(
            connectorId: "src-2", externalId: "evt-2", lastModified: base.addingTimeInterval(-60), location: "B"
        )
        let event = try MeetingEvent(
            id: eventId, sourceConnectorId: "src-1", externalId: "evt-1", icalUid: "shared-uid", title: "T",
            start: base, end: base.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false, isCancelled: false,
            organizer: nil, attendees: [], location: "A", bodyText: nil, conference: nil, lastModified: base
        )
        let sources = [
            MeetingSource(
                sourceConnectorId: "src-1", externalId: "evt-1", icalUid: "shared-uid",
                lastModified: base, payload: payloadA
            ),
            MeetingSource(
                sourceConnectorId: "src-2", externalId: "evt-2", icalUid: "shared-uid",
                lastModified: base.addingTimeInterval(-60), payload: payloadB
            )
        ]
        harness.meetingRepository.seed([MeetingRecord(event: event, dedupKey: nil, status: .ready, sources: sources)])

        connector.setFetchChanges(ChangeBatch(
            events: [], deletedExternalIds: ["evt-1"], cursor: "cursor-1", resetRequired: false
        ))

        let results = await harness.hub.sync(trigger: .manual)

        XCTAssertNil(results.first?.failure)
        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.sources.count, 1)
        XCTAssertEqual(stored.first?.event.sourceConnectorId, "src-2", "identity — единственный оставшийся источник")
        XCTAssertEqual(
            stored.first?.event.location, "B",
            "содержимое пересчитано ПОЛНЫМ слиянием (Self.merge), не заморожено — у B есть снимок"
        )
    }

    // MARK: - Инв. 10/11 (C-005): слияние по снимкам всех источников, сериализация по встрече

    /// Рабочий пример РП (MEE-385, 24.09 17:45 UTC): A(lm=3, nil), B(lm=2, «X»), C(lm=1, «Y»)
    /// → «X». Три источника с общим дедуп-ключом (`icalUid`) сообщают об одной встрече ОДНИМ
    /// циклом `sync()` — `TaskGroup` заводит по задаче на источник, все три параллельно
    /// сходятся на один и тот же дедуп-ключ. Победитель шага 1 — A (наибольший lastModified);
    /// его `location == nil` — шаг 2 уходит к первому источнику со снимком в порядке
    /// возрастания `sourceConnectorId` среди остальных — это B («X»), не C.
    ///
    /// Возврат РП (приёмка #105, п. 3): этот тест доказывает только ПРАВИЛЬНОСТЬ ИТОГА при
    /// реальном планировщике `TaskGroup` — он, скорее всего, прошёл бы и без сериализации
    /// (три задачи короткие, конкретное чередование не форсируется). Настоящее доказательство
    /// самой сериализации — `test_k77_secondMergeOfSameMeetingDoesNotStartUntilFirstFinishes`
    /// (`MergeTests+Serialization.swift`).
    ///
    /// К76 (перечень MEE-347, дельта под C-005 v14, группа М) — этот тест и
    /// `test_ir126_sequentialCyclesInOrder_C_A_B_matchRPWorkedExample`
    /// (`MergeCrossCycleTests.swift`) вместе покрывают тот же рабочий пример РП только
    /// ЧАСТИЧНО (возврат РП, 24.09, MEE-361, приёмка дельты b943cc7e): К76 требует ОДНО общее
    /// слияние трёх источников, ЗАТЕМ частичный второй цикл, где сообщает только C (снимки A и
    /// B при этом обязаны перенестись из первого цикла) — ни этот тест (одно совместное
    /// слияние, без второго цикла), ни соседний (три отдельных последовательных
    /// однокисточниковых цикла) не строят именно эту конструкцию входа. СТРОКА: тест на К76
    /// дословно не заведён — вне объёма этой правки (зона МЕЕ-386 продолжает держать пробел
    /// явно).
    func test_inv10_inv11_threeSourcesConcurrentMergeMatchesRPWorkedExample() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A", "B", "C"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        harness.connector("A").setFetchEvents([
            try mergeTestPayload(connectorId: "A", externalId: "evt-a", lastModified: base.addingTimeInterval(3))
        ])
        harness.connector("B").setFetchEvents([
            try mergeTestPayload(
                connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(2), location: "X"
            )
        ])
        harness.connector("C").setFetchEvents([
            try mergeTestPayload(
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

    // Доказательство самой сериализации инв. 11/К77 (не только её результата, доказанного
    // тестом выше) — `MergeTests+Serialization.swift` (тот же довод file_length/
    // type_body_length, что развёл этот файл и `MergeCrossCycleTests.swift`).
}
