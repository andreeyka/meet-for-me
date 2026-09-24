//  Дедуп-ключ, назначение id, правило слияния — группа В плана MEE-361 (К15-К29). К23/К24/
//  К27-К29 — в `DedupAndMergeStepsTests.swift` (та же причина, что развела
//  `CalendarPortImplSync.swift`/`CalendarPortImplMerge.swift`: SwiftLint `type_body_length`
//  считает каждое расширение типа отдельно).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен
//
//  Возврат РП (возврат по MEE-386, «часть 3г», п. 3, 24.09): порция К из перечня MEE-347,
//  группа В. К16/К26 и часть К15 (нормализация join-URL) закрыты ОДНИМ интеграционным
//  тестом — внутреннее поведение `DedupKey.make` (приоритет ветвей, детерминированность,
//  границы) уже дословно закрыто `DomainCoreTests/DedupKeyTests.swift`, владельцем самой
//  функции; здесь доказывается только то, что `calendar-hub` реально ЗОВЁТ эту функцию, а
//  не обходит её и не реализует дедуп сам. К18/К19 (fallback на пару
//  sourceConnectorId/externalId при несовпадающем dedupKey, коллизия двух кандидатов) в эту
//  порцию не входят — оставлены следующей.
//
//  Оснастка (`mergeTestPayload`, `mergeTestAttendee`, `Harness.mergeReady`) — общая,
//  `TestSupport.swift`.

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class DedupAndMergeTests: XCTestCase {

    // MARK: - К16/К26 (и часть К15): calendar-hub зовёт настоящий DedupKey.make

    /// РП, приёмка MEE-361 (13:05): единственный тест `calendar-hub` для К15/К16/К25/К26 —
    /// событие, поданное через ФК, приходит в сохранённую `MeetingRecord.dedupKey` со
    /// значением, равным ПРЯМОМУ вызову `DedupKey.make(from: то же событие)` в теле теста.
    /// Доказывает вызов настоящей функции, не подмену/реимплементацию нормализации или
    /// дедупа внутри `calendar-hub`.
    func test_v_hostInvokesDedupKeyMakeNotOwnNormalization() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let connector = harness.connector("src-1")
        let lastModified = Date(timeIntervalSince1970: 1_700_000_100)
        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: lastModified)
        ])

        let results = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(results.first?.failure)

        let record = try XCTUnwrap(harness.meetingRepository.storedRecords.first)
        XCTAssertEqual(
            record.dedupKey, DedupKey.make(from: record.event),
            "dedupKey обязан быть прямым вызовом настоящей DedupKey.make, не своей копией"
        )
    }

    // MARK: - К17: совпадающий dedupKey (признак а) переиспользует существующий id

    /// Другой `externalId` (признак (б) — пара sourceConnectorId/externalId — не совпадёт),
    /// тот же `icalUid` ("shared-uid", умолчательный из `mergeTestPayload`) → тот же
    /// dedupKey (признак (а)) — `assigningId` обязан взять id УЖЕ существующей записи, не
    /// завести новую.
    func test_k17_matchingDedupKeyAssignsExistingId() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let connector = harness.connector("src-1")
        let base = Date(timeIntervalSince1970: 1_700_000_100)

        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base)
        ])
        let firstResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(firstResults.first?.failure)
        let existingId = try XCTUnwrap(harness.meetingRepository.storedRecords.first?.event.id)

        connector.setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-2", lastModified: base.addingTimeInterval(60))
        ])
        let secondResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(secondResults.first?.failure)

        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1, "совпадающий dedupKey (признак а) не заводит новую запись")
        XCTAssertEqual(stored.first?.event.id, existingId, "assigningId обязан использовать id существующей записи")
    }

    // MARK: - К20-К22: шаги 1-3 правила слияния

    /// Вход А: равный dedupKey, разный `lastModified` → победитель — больший `lastModified`.
    /// Вход Б (ничья): равный `lastModified`, разный `sourceConnectorId` → победитель —
    /// лексикографически меньший `sourceConnectorId`.
    func test_k20_winnerByLastModifiedThenBySourceConnectorId() async throws {
        let harnessA = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        let base = Date(timeIntervalSince1970: 1_700_000_100)
        harnessA.connector("src-1").setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: base)
        ])
        harnessA.connector("src-2").setFetchEvents([
            try mergeTestPayload(connectorId: "src-2", externalId: "evt-2", lastModified: base.addingTimeInterval(60))
        ])
        let resultsA = await harnessA.hub.sync(trigger: .manual)
        for result in resultsA { XCTAssertNil(result.failure) }
        let storedA = harnessA.meetingRepository.storedRecords
        XCTAssertEqual(storedA.count, 1, "общий icalUid — одна встреча")
        XCTAssertEqual(storedA.first?.event.sourceConnectorId, "src-2", "больший lastModified побеждает")

        let harnessB = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        let tie = Date(timeIntervalSince1970: 1_700_000_200)
        harnessB.connector("src-1").setFetchEvents([
            try mergeTestPayload(connectorId: "src-1", externalId: "evt-1", lastModified: tie)
        ])
        harnessB.connector("src-2").setFetchEvents([
            try mergeTestPayload(connectorId: "src-2", externalId: "evt-2", lastModified: tie)
        ])
        let resultsB = await harnessB.hub.sync(trigger: .manual)
        for result in resultsB { XCTAssertNil(result.failure) }
        let storedB = harnessB.meetingRepository.storedRecords
        XCTAssertEqual(storedB.count, 1)
        XCTAssertEqual(
            storedB.first?.event.sourceConnectorId, "src-1",
            "ничья по lastModified — меньший sourceConnectorId побеждает"
        )
    }

    /// Победитель содержимого (больший `lastModified`) с `location == nil`, проигравший — с
    /// непустым → скаляр результата — первое не-`nil` среди ОСТАЛЬНЫХ источников (здесь
    /// единственный остальной).
    func test_k21_scalarsFromWinnerFallbackToFirstNonNil() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        let base = Date(timeIntervalSince1970: 1_700_000_100)

        harness.connector("src-1").setFetchEvents([
            try mergeTestPayload(
                connectorId: "src-1", externalId: "evt-1", lastModified: base.addingTimeInterval(60), location: nil
            )
        ])
        harness.connector("src-2").setFetchEvents([
            try mergeTestPayload(connectorId: "src-2", externalId: "evt-2", lastModified: base, location: "Room 42")
        ])
        let results = await harness.hub.sync(trigger: .manual)
        for result in results { XCTAssertNil(result.failure) }

        let stored = try XCTUnwrap(harness.meetingRepository.storedRecords.first)
        XCTAssertEqual(stored.event.sourceConnectorId, "src-1", "победитель содержимого — больший lastModified")
        XCTAssertEqual(stored.event.location, "Room 42", "победитель без location — первое не-nil среди остальных")
    }

    /// Общий `email`, разный `responseStatus` (здесь — разное имя, тот же email) →
    /// сохраняется запись победителя содержимого. Два участника с `email == nil`, разные
    /// `name` → оба добавлены. Совпадающий `name` при `email == nil` — не дублируется.
    func test_k22_attendeesUnionByEmailThenByDistinctName() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        let base = Date(timeIntervalSince1970: 1_700_000_100)

        let winnerAttendee = try mergeTestAttendee(name: "Winner Name", email: "shared@example.com")
        let loserAttendeeSameEmail = try mergeTestAttendee(name: "Loser Name", email: "shared@example.com")
        let noEmailA = try mergeTestAttendee(name: "No Email A", email: nil)
        let noEmailB = try mergeTestAttendee(name: "No Email B", email: nil)
        let noEmailADuplicateName = try mergeTestAttendee(name: "No Email A", email: nil)

        harness.connector("src-1").setFetchEvents([
            try mergeTestPayload(
                connectorId: "src-1", externalId: "evt-1", lastModified: base.addingTimeInterval(60),
                attendees: [winnerAttendee, noEmailA]
            )
        ])
        harness.connector("src-2").setFetchEvents([
            try mergeTestPayload(
                connectorId: "src-2", externalId: "evt-2", lastModified: base,
                attendees: [loserAttendeeSameEmail, noEmailB, noEmailADuplicateName]
            )
        ])
        let results = await harness.hub.sync(trigger: .manual)
        for result in results { XCTAssertNil(result.failure) }

        let attendees = try XCTUnwrap(harness.meetingRepository.storedRecords.first?.event.attendees)
        XCTAssertEqual(attendees.count, 3, "shared@example.com дедуплицирован, No Email A по имени — тоже")
        XCTAssertTrue(
            attendees.contains { $0.person.email == "shared@example.com" && $0.person.name == "Winner Name" },
            "на совпадении email побеждает запись победителя содержимого (src-1, больший lastModified)"
        )
        XCTAssertTrue(attendees.contains { $0.person.name == "No Email A" && $0.person.email == nil })
        XCTAssertTrue(attendees.contains { $0.person.name == "No Email B" && $0.person.email == nil })
    }
}
