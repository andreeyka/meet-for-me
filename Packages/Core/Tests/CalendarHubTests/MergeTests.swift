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
//  `.upserted` проверен и в ветке без снимков (`test_inv10_identityRecomputedWhenDepartedSourceWasIdentity`).

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

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

    /// Возврат РП (приёмка #105, п. 2/3, уточнено 18:55 UTC): доказательство самой
    /// сериализации, не только её результата. Первое слияние подвешено НА
    /// `MeetingRepository.save(_:)` — ворота с ручным отпуском (`gate(on:)`/`release(on:)`),
    /// не `hang` на фиксированную секунду (тот был здесь раньше — момент отпуска решала
    /// гонка с часами, не тест явно). Пока оно висит там — второе слияние ТОЙ ЖЕ встречи не
    /// вправе даже НАЧАТЬ своё тело (не то что дойти до своего `save`): при верной
    /// сериализации (единая цепочка `mergeTail`)
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

        // Возврат РП (приёмка #105, 18:55 UTC): ворота с ручным отпуском, не `hang` на
        // фиксированную секунду — момент отпуска решает тест явно, не гонка с часами.
        harness.meetingRepository.gate(on: .save)
        let syncTask = Task { await harness.hub.sync(trigger: .manual) }

        await pollUntil(timeout: .seconds(2)) {
            meetingRepositorySaveCallCount(harness.meetingRepository) >= 1
        }
        // Первый save уже встал на воротах. Второй источник не должен был успеть догнать
        // его своим собственным save, пока первый не отпущен, — короткая пауза здесь не
        // определяет корректность (ворота без неё уже держат первый вызов бесконечно), она
        // только даёт шанс сломанной реализации СОВЕРШИТЬ гонку до проверки.
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            meetingRepositorySaveCallCount(harness.meetingRepository), 1,
            "второе слияние не вправе начать СВОЁ тело (и дойти до своего save), пока первое не завершилось (инв. 11)"
        )

        harness.meetingRepository.stopGating(on: .save)
        harness.meetingRepository.release(on: .save)
        let results = await syncTask.value
        XCTAssertTrue(results.allSatisfy { $0.failure == nil })
        XCTAssertEqual(meetingRepositorySaveCallCount(harness.meetingRepository), 2, "оба слияния в итоге сохранились")
        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1, "общий дедуп-ключ — одна встреча")
        XCTAssertEqual(stored.first?.sources.count, 2, "ни один источник не потерян")
    }

    /// Возврат РП (приёмка #105, 18:55 UTC): инв. 11 — не только когда два источника СОВПАДАЮТ
    /// по вычисленному `DedupKey` (общий `icalUid` в тесте выше делает это по построению).
    /// Здесь — ДВА ОБНОВЛЕНИЯ ОДНОЙ И ТОЙ ЖЕ пары (`sourceConnectorId`/`externalId`), но с
    /// РАЗНЫМИ `DedupKey`: первое без `icalUid` (ключ через `organizer.email`), второе — с
    /// `icalUid` (другая ветвь `DedupKey`, C-005 инв. 2). Старый словарь `mergeTail` по ключу
    /// сериализовал бы их на РАЗНЫЕ записи словаря — оба одновременно не находят
    /// существующую запись НИ по `meeting(dedupKey:)` (разные ключи, пары ещё нет), НИ по
    /// `meeting(sourceConnectorId:externalId:)` (гонка застаёт обоих ДО save друг друга) —
    /// и `save` второго бросил бы `constraintViolation` (инв. 30 C-010: пара уже занята
    /// встречей, которую сохранил первый). Верная (единая цепочка) сериализация не даёт
    /// этой гонке случиться вовсе — второй вызов видит запись первого уже сохранённой.
    func test_inv11_differentDedupKeysSameSourcePairDoesNotRaceIntoConstraintViolation() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let withoutIcalUid = try MeetingEventPayload(
            sourceConnectorId: "A", externalId: "evt-a", icalUid: nil, title: "T",
            start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
            isCancelled: false, organizer: try MeetingEvent.Person(name: "Ivan", email: "organizer@example.com"),
            attendees: [], location: nil, bodyText: nil, conference: nil, lastModified: base
        )
        let withIcalUid = try MeetingEventPayload(
            sourceConnectorId: "A", externalId: "evt-a", icalUid: "uid-1", title: "T",
            start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
            isCancelled: false, organizer: nil, attendees: [], location: "X", bodyText: nil,
            conference: nil, lastModified: base.addingTimeInterval(1)
        )
        XCTAssertNotEqual(
            DedupKey.make(from: try withoutIcalUid.assigningId(UUID())),
            DedupKey.make(from: try withIcalUid.assigningId(UUID())),
            "оснастка теста: два payload'а обязаны давать РАЗНЫЕ DedupKey, иначе сценарий не тот"
        )

        harness.meetingRepository.gate(on: .save)
        let firstTask = Task { try await harness.hub.applyIncoming(payload: withoutIcalUid) }

        await pollUntil(timeout: .seconds(2)) { meetingRepositorySaveCallCount(harness.meetingRepository) >= 1 }
        let secondTask = Task { try await harness.hub.applyIncoming(payload: withIcalUid) }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(
            meetingRepositorySaveCallCount(harness.meetingRepository), 1,
            "разные DedupKey не освобождают второй вызов от ожидания — сериализация НЕ по ключу (инв. 11)"
        )

        harness.meetingRepository.stopGating(on: .save)
        harness.meetingRepository.release(on: .save)

        _ = try await firstTask.value
        _ = try await secondTask.value

        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1, "одна и та же пара источника — одна встреча, не constraintViolation")
        XCTAssertEqual(stored.first?.sources.count, 1, "обновление той же пары заменяет снимок, не добавляет второй")
        XCTAssertEqual(
            stored.first?.event.location, "X",
            "второе (более позднее) обновление содержимого победило"
        )
    }
}
