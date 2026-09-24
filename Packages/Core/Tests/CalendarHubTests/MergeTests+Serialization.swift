//  Продолжение `MergeTests.swift` — доказательства самой сериализации инв. 11 (не только её
//  результата), вынесено отдельным файлом той же причиной, что развела
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
    ///
    /// К77 (перечень MEE-347, дельта под C-005 v14, группа М) — кандидат на этот критерий, с
    /// двумя ОТКРЫТЫМИ расхождениями (возврат РП, 24.09, MEE-361, приёмка дельты b943cc7e,
    /// п. 2 — не устранены этой правкой, зона МЕЕ-386 продолжает их держать явно, не молчком):
    /// (1) вход перечня называет конкретную УЖЕ ИЗВЕСТНУЮ встречу (`eventkit-1`/«evt-7» +
    /// `graph-work-1`/«evt-9»), этот тест — новую, ещё не существующую («A»/«B»); (2) «второе
    /// не стартовало» ловится паузой `Task.sleep(50ms)` выше — сломанная сериализация ловится
    /// лишь с вероятностью (окно гонки, не гарантия), не детерминированным механизмом, каким
    /// иначе последовательно пользуется этот модуль (`gate`/`release`).
    /// СТРОКА: устранение обоих расхождений (либо доказательство, что байт-точная ассерция
    /// `raw_payload_json` уже здесь не нужна) в этой правке не решается — вне её объёма.
    func test_k77_secondMergeOfSameMeetingDoesNotStartUntilFirstFinishes() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A", "B"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let payloadA = try mergeTestPayload(connectorId: "A", externalId: "evt-a", lastModified: base)
        let payloadB = try mergeTestPayload(
            connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(1)
        )
        harness.connector("A").setFetchEvents([payloadA])
        harness.connector("B").setFetchEvents([payloadB])

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
        // Возврат РП (24.09, MEE-361, приёмка дельты b943cc7e, п. 2): К77 требует байт-точное
        // равенство raw_payload_json каждой строки её payload (C-010 v18 инв. 31), не только
        // присутствие обоих источников.
        let snapshotA = stored.first?.sources.first { $0.sourceConnectorId == "A" }?.payload
        XCTAssertEqual(snapshotA, payloadA, "raw_payload_json источника A побайтово равен своему payload")
        let snapshotB = stored.first?.sources.first { $0.sourceConnectorId == "B" }?.payload
        XCTAssertEqual(snapshotB, payloadB, "raw_payload_json источника B побайтово равен своему payload")
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
    ///
    /// К77 (возврат РП, 24.09, приёмка #115, «Номера К») — смежный, не тот же вектор:
    /// `test_k77_secondMergeOfSameMeetingDoesNotStartUntilFirstFinishes` (выше в этом файле)
    /// про ДВА РАЗНЫХ источника одной уже известной встречи, здесь — ДВЕ пары одного и того
    /// же источника с разными `DedupKey` (см. докстринг выше). Тот же механизм (`gate`/
    /// `release` на `save`), другой сценарий инв. 11 — не переименован под `test_k77_`, чтобы
    /// не заявлять дословное совпадение, которого нет.
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
