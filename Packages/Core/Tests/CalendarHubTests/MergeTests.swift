//  IR-126 (MEE-372/MEE-385) — слияние по снимкам источников между синхронизациями (C-005
//  v14 инв. 10/11), перенос payload в applyIncoming. Номера К — дельта перечня MEE-347 под
//  C-005 v14, на возврате у аналитика на момент этой правки (РП, 24.09 17:45 UTC) — тесты
//  названы по инвариантам контракта, не по К, до выхода дельты; переименовать после её
//  выхода не будет стоить ничего по существу — вход/ответ здесь взяты из контракта, не
//  придуманы.
//
//  Возврат РП (приёмка #105, 18:25 UTC) — identity/содержимое при уходе источника (п. 1) и
//  настоящее доказательство сериализации инв. 11 воротами `save` (п. 2/3), не только её
//  результата. Остальные новые тесты возврата (IR-126 последовательными циклами, attendees,
//  отказ источника в цикле) — `MergeCrossCycleTests.swift`, той же причиной разнесено, что
//  развело `CalendarPortImplSync.swift`/`CalendarPortImplMerge.swift`: SwiftLint `file_length`
//  считает каждый файл отдельно, и один файл на все семь новых/переписанных тестов вышел бы
//  за лимит. Общая оснастка (`mergeTestPayload`, `mergeTestAttendee`,
//  `meetingRepositorySaveCallCount`) — `TestSupport.swift`, одна на оба файла.

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
    /// сохранении с одним источником). Ни у одного из двух источников здесь снимка нет —
    /// содержимое остаётся замороженным (см. следующий тест на случай, когда снимок есть).
    func test_inv10_identityRecomputedWhenDepartedSourceWasIdentity() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"], deltaSync: true, cursor: "cursor-0")
        let connector = harness.connector("src-1")

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

    /// Возврат РП (приёмка #105, п. 1): A и B — ОБА со снимками (в отличие от теста выше,
    /// где снимков нет ни у кого). A — identity и содержимое, B — второй источник с
    /// собственным снимком. A уходит — у оставшегося B есть снимок, значит правило C-005
    /// шагов 1-6 обязано пересчитать НЕ ТОЛЬКО identity, но и содержимое целиком
    /// (`Self.merge(sources: remaining, …)`), а не оставлять прежний текст `location`.
    func test_inv10_identityAndContentRecomputedWhenDepartedSourceHadSnapshot() async throws {
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
    /// самой сериализации — соседний `test_inv11_secondMergeOfSameMeetingDoesNotStartUntilFirstFinishes`.
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

    /// Возврат РП (приёмка #105, п. 2/3): доказательство самой сериализации, не только её
    /// результата. Первое слияние подвешено НА `MeetingRepository.save(_:)` (ворота фейка,
    /// `hang(on:)` — тот же приём, что `InitializationTests.resolveTimeoutAfterHang`), пока
    /// оно висит там — второе слияние ТОЙ ЖЕ встречи не вправе даже НАЧАТЬ своё тело (не то
    /// что дойти до своего `save`): при верной сериализации (единая цепочка `mergeTail`)
    /// счётчик вызовов `save(_:)` обязан оставаться равным 1, пока первый вызов не отпущен —
    /// счётчик реагирует раньше первого `await` второго тела, так что тест не гадает по
    /// таймингу самого слияния, только по свежему логу вызовов порта.
    ///
    /// Старый словарь `mergeTail: [DedupKey: Task<Void, Never>]` этот тест бы НЕ прошёл: два
    /// источника новой (ещё не существующей) встречи вычисляют СВОИ `DedupKey.make(from:)` из
    /// разных `assigningId(UUID())` `id`, но одинакового `icalUid` — ключ совпадает только
    /// потому, что `DedupKey` строится из `icalUid`, когда он есть; проверка воротами именно
    /// СЧЁТЧИКА `save`, а не текста ключа, — прямое наблюдение за фактическим порядком, не за
    /// побочным совпадением значений ключа в этом конкретном сценарии.
    func test_inv11_secondMergeOfSameMeetingDoesNotStartUntilFirstFinishes() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A", "B"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        harness.connector("A").setFetchEvents([
            try mergeTestPayload(connectorId: "A", externalId: "evt-a", lastModified: base)
        ])
        harness.connector("B").setFetchEvents([
            try mergeTestPayload(connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(1))
        ])

        harness.meetingRepository.hang(on: .save, seconds: 0.4)
        let syncTask = Task { await harness.hub.sync(trigger: .manual) }

        await pollUntil(timeout: .seconds(2)) {
            meetingRepositorySaveCallCount(harness.meetingRepository) >= 1
        }
        // Первый save уже начался (висит в hang). Второй источник не должен был успеть
        // догнать его своим собственным save, пока первый не отпущен воротами — проверяем
        // это ДО истечения hangSeconds, пока сама возможность гонки ещё не закрылась временем.
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(
            meetingRepositorySaveCallCount(harness.meetingRepository), 1,
            "второе слияние не вправе начать СВОЁ тело (и дойти до своего save), пока первое не завершилось (инв. 11)"
        )

        let results = await syncTask.value
        XCTAssertTrue(results.allSatisfy { $0.failure == nil })
        XCTAssertEqual(meetingRepositorySaveCallCount(harness.meetingRepository), 2, "оба слияния в итоге сохранились")
        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1, "общий дедуп-ключ — одна встреча")
        XCTAssertEqual(stored.first?.sources.count, 2, "ни один источник не потерян")
    }
}
