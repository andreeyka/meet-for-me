//  IR-126 (MEE-372/MEE-385) — слияние по снимкам источников между синхронизациями (C-005
//  v14 инв. 10/11), продолжение `MergeTests.swift`: тесты, добавленные и переписанные
//  возвратом РП (приёмка #105, 18:25 UTC, п. 3).
//
//  Разнесено на отдельный файл от `MergeTests.swift` — SwiftLint `file_length` считает
//  каждый файл отдельно (тот же приём, что развёл `CalendarPortImplSync.swift`/
//  `CalendarPortImplMerge.swift`): семь тестов возврата в одном файле вышли бы за лимит.
//  Оснастка (`mergeTestPayload`, `mergeTestAttendee`, `seedTwoSourceMeetingIdentityB`) —
//  общая, `TestSupport.swift`.
//
//  Возврат РП (18:55 UTC, MEE-386) усилил два теста этого файла (доводы — в их докстрингах):
//  IR-126 проверяет снимки C/A НАПРЯМУЮ, не только производное поле `location`; отказ
//  источника проверяется НЕ тривиально — сосед действительно обновляется в том же цикле.

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
        // Возврат РП (приёмка #105, 18:55 UTC): итоговое поле `location` само по себе не
        // различает «снимок C цел» от «снимок C потерян, но B случайно даёт тот же ответ» —
        // C здесь ни на что не влияет (B побеждает шагом 2 и без него). Проверяем снимки
        // C и A НАПРЯМУЮ — каждый обязан пережить циклы, где сообщает не его источник.
        let snapshotC = stored.first?.sources.first { $0.sourceConnectorId == "C" }?.payload
        XCTAssertEqual(snapshotC?.location, "Y", "снимок C (цикл 1) обязан пережить циклы 2 и 3, где C молчит")
        let snapshotA = stored.first?.sources.first { $0.sourceConnectorId == "A" }?.payload
        // Возврат РП (приёмка #109, 19:25 UTC): XCTAssertNil(snapshotA?.location) проходит и
        // при ПОТЕРЯННОМ снимке — nil?.location тоже nil. XCTAssertNotNil(snapshotA) отдельно
        // доказывает, что снимок A вообще ЖИВ (а не просто его поле location случайно nil).
        XCTAssertNotNil(snapshotA, "снимок A (цикл 2) обязан пережить цикл 3, где A молчит, а не пропасть вовсе")
        XCTAssertNil(snapshotA?.location, "у снимка A location == nil по построению цикла 2 — не потеря снимка")
    }

    /// Перенос снимков между циклами (инв. 10): цикл, в котором сообщил только B, не трогает
    /// снимок A — A переносится дословно из уже сохранённого состояния (`sources.filter`
    /// в `mergeIncoming`), не пересобирается заново со значением `payload == nil`.
    ///
    /// К79 (перечень MEE-347, дельта под C-005 v14, группа М): снимок неотчитавшегося
    /// источника после цикла переносится дословно, не только его `location`.
    ///
    /// Возврат РП (приёмка #105, п. 3): раньше B был содержательным победителем В ОБОИХ
    /// циклах САМ ПО СЕБЕ (его `location` всегда непуст) — перенесённый снимок A ни на что
    /// не влиял, и сломанный перенос снимков этот тест бы не поймал. Во втором цикле у B
    /// `location == nil` — итоговое значение обязано прийти от перенесённого снимка A.
    ///
    /// Возврат РП (24.09, MEE-361, приёмка дельты b943cc7e, п. 1): раньше проверялся только
    /// `snapshotA?.location` — этого не хватает на «снимок цел целиком», та же мерка, что и
    /// у К77 (байт-точное равенство), нужна и здесь. `XCTAssertEqual(snapshotA, payloadA)`
    /// ниже сравнивает ВЕСЬ перенесённый снимок с исходным payload, не только одно поле.
    func test_k79_unreportingSourceKeepsCarriedOverSnapshot() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A", "B"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let payloadA = try mergeTestPayload(
            connectorId: "A", externalId: "evt-a", lastModified: base.addingTimeInterval(1), location: "A1"
        )
        harness.connector("A").setFetchEvents([payloadA])
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
        XCTAssertEqual(snapshotA, payloadA, "снимок A перенесён дословно целиком, не тронут вторым циклом")
        let snapshotB = stored.first?.sources.first { $0.sourceConnectorId == "B" }?.payload
        XCTAssertNil(snapshotB?.location, "снимок B обновлён свежим payload (тоже дословно, включая nil)")
        XCTAssertEqual(stored.first?.event.sourceConnectorId, "B", "identity — теперь B, его lastModified больше")
        XCTAssertEqual(
            stored.first?.event.location, "A1",
            "B — содержательный победитель, но его снимок location == nil — шаг 2 уходит к перенесённому A"
        )
    }

    // MARK: - Шаг 3 (C-005): объединение attendees

    /// К22 (шаг 3 правила слияния), дополняет `test_k22_attendeesUnionByEmailThenByDistinctName`
    /// (`DedupAndMergeTests.swift`) другим углом — тот берёт двух участников общего email
    /// внутри уже готовых payload'ов, этот доказывает сам МЕХАНИЗМ объединения по источникам:
    /// содержательный победитель (A, наибольший lastModified) даёт свой список первым,
    /// остальные источники (B, не победитель) добавляют СВОИХ участников — по email побеждает
    /// первая встреченная запись (та, что уже добавлена от победителя), участник без email
    /// добавляется, только если его `name` ещё не встречалось.
    ///
    /// Возврат РП (24.09, MEE-361, приёмка дельты b943cc7e, п. 3): привязан к К явно —
    /// докстрока раньше номер К не называла вовсе.
    func test_k22_attendeesUnionFromNonWinnerDedupedByEmailAndName() async throws {
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

    /// К80 (перечень MEE-347, дельта под C-005 v14, группа М): источник, отказавший в цикле
    /// (инв. 8), не лишается уже сохранённого снимка — его строка остаётся в `meeting_sources`
    /// нетронутой, не только производное поле `location`.
    ///
    /// Возврат РП (приёмка #105, п. 3): `fetchEvents` источника A бросает ошибку — его
    /// собственный цикл синхронизации обязан отказать (К13), но НИ ОДИН уже сохранённый
    /// снимок (ни его собственный, ни снимок B) не вправе быть тронут — `applyIncoming`
    /// вообще не вызывается для отказавшего источника этим циклом (отказ происходит ДО
    /// первого обращения к `meetingRepository`).
    ///
    /// Возврат РП (приёмка #105, 18:55 UTC): «отказ не должен проходить тривиально» — раньше
    /// B в этом же цикле ничего НЕ сообщал (`setFetchEvents([])`), а проверка «снимок A цел»
    /// прошла бы даже нулевой реализацией (нечему было бы его тронуть, слияние в этом цикле
    /// вообще не запускалось бы). Теперь B ДЕЙСТВИТЕЛЬНО обновляется в ТОМ ЖЕ цикле — с
    /// бо́льшим `lastModified`, но БЕЗ `location` — так что итоговый `location` обязан прийти
    /// именно из перенесённого снимка A (шаг 2), доказывая, что слияние этого цикла реально
    /// ПРОЧИТАЛО снимок A, а не просто не успело его коснуться.
    ///
    /// Возврат РП (24.09, MEE-361, приёмка дельты b943cc7e, п. 1): раньше проверялся только
    /// `snapshotA?.location` — та же мерка, что и у К77/К79, нужна и здесь. `expectedPayloadA`
    /// воспроизводит ровно то, что строит `seedTwoSourceMeetingIdentityB` внутри себя для A —
    /// `XCTAssertEqual(snapshotA, expectedPayloadA)` сравнивает снимок целиком.
    func test_k80_sourceFailureInCycleKeepsOtherSourcesSnapshotsIntact() async throws {
        let harness = Harness.mergeReady(sourceIds: ["A", "B"])
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        try seedTwoSourceMeetingIdentityB(harness, base: base, locationA: "A1", locationB: "B1")
        let expectedPayloadA = try mergeTestPayload(
            connectorId: "A", externalId: "evt-a", lastModified: base, location: "A1"
        )

        harness.connector("A").fail(.fetchEvents, with: .upstreamUnavailable(message: "boom"))
        harness.connector("B").setFetchEvents([
            try mergeTestPayload(
                connectorId: "B", externalId: "evt-b", lastModified: base.addingTimeInterval(2), location: nil
            )
        ])

        let results = await harness.hub.sync(trigger: .manual)

        let failedA = results.first { $0.sourceId == CalendarSourceId(rawValue: "A") }
        XCTAssertNotNil(failedA?.failure, "A обязан отказать этим циклом")
        let okB = results.first { $0.sourceId == CalendarSourceId(rawValue: "B") }
        XCTAssertNil(okB?.failure, "отказ A не задевает цикл B")

        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.sources.count, 2, "отказ A не удаляет ни его, ни чужой источник")
        let snapshotA = stored.first?.sources.first { $0.sourceConnectorId == "A" }?.payload
        XCTAssertEqual(
            snapshotA, expectedPayloadA, "снимок A цел целиком — его цикл не дошёл до meetingRepository вовсе"
        )
        let snapshotB = stored.first?.sources.first { $0.sourceConnectorId == "B" }?.payload
        XCTAssertNil(snapshotB?.location, "снимок B обновлён свежим payload этого цикла (тоже дословно, включая nil)")
        XCTAssertEqual(stored.first?.event.sourceConnectorId, "B", "identity — теперь B, его lastModified больше")
        XCTAssertEqual(
            stored.first?.event.location, "A1",
            "B — содержательный победитель, но его снимок location == nil — слияние реально читает снимок A"
        )
    }
}
