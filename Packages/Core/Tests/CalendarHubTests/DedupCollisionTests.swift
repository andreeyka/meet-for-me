//  К19 (перечень MEE-347, C-005 v14 правило слияния п.4) — коллизия двух кандидатов:
//  признак (а) и признак (б) (по паре ТОГО ЖЕ payload'а) указывают на РАЗНЫЕ существующие
//  записи. Отдельный файл — новая логика (`CalendarPortImplMerge.swift`, `mergeIncoming`),
//  не тест на уже существующее поведение (в отличие от К17/К18 рядом).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class DedupCollisionTests: XCTestCase {

    /// UUID фиксированы, не случайны (возврат РП, 24.09 23:12 UTC, п. 3) — со случайными
    /// `UUID()` какая из двух ветвей тернарника `mergeIncoming` (X меньше / Y меньше)
    /// сработает, решает монетка каждого запуска; `idLow`/`idHigh` детерминируют это, и оба
    /// теста ниже вместе гарантированно упражняют ОБЕ ветви на каждом прогоне CI.
    private static let idLow = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private static let idHigh = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    /// Признак (а) (по вычисленному `DedupKey` входящего payload'а) находит X, признак (б)
    /// (по паре ТОГО ЖЕ payload'а) — Y, X ≠ Y: два разных существующих кандидата. Ответ:
    /// побеждает запись с лексикографически меньшим `id.uuidString`; источники проигравшей
    /// переходят победителю, её `id` публикуется `.deleted` (К39 вход А), СРАЗУ ЗА КОТОРЫМ
    /// (возврат РП, п. 3) идёт `.upserted` слитой записи — не наоборот, не вперемешку с
    /// другими событиями потока.
    ///
    /// СТРОКА (буквальное прочтение, возврат РП 24.09 22:57 UTC — см. докстринг
    /// `mergeIncoming`, `CalendarPortImplMerge.swift`): X и Y здесь заведены СЕМАНТИЧЕСКИ
    /// не связанными (X с `icalUid`, Y без) — единственный проверяемый здесь код-путь
    /// коллизии тот, где входящий payload сам указывает на Y своей парой
    /// (`sourceConnectorId`/`externalId`), но вычисляет `DedupKey`, совпадающий с уже
    /// сохранённым `dedupKey` X.
    func test_k19_xWinsByLexicographicallySmallerId() async throws {
        try await Self.runCollision(idX: Self.idLow, idY: Self.idHigh)
    }

    /// Тот же сценарий, `id` у X/Y поменяны местами — упражняет ВТОРУЮ ветвь тернарника
    /// (`byPair` меньше `byKey`), не покрытую соседним тестом.
    func test_k19_yWinsByLexicographicallySmallerId() async throws {
        try await Self.runCollision(idX: Self.idHigh, idY: Self.idLow)
    }

    /// Возврат РП (приёмка #135, очередь после): атомарность через фейк. MEE-407
    /// (`save(_:absorbing:)`, C-010 v21/v22 инв. 33) заменила раздельные `delete()`+`save()`
    /// в `mergeIncoming` — до этого отказ `save()` ПОСЛЕ уже прошедшего `delete()` терял бы
    /// проигравшую запись без следа (собственная СТРОКА `CalendarPortImplMerge.swift` до
    /// этой правки). Доказательство: `save(_:absorbing:)` настроен на отказ — ни проигравшая,
    /// ни выигравшая запись не изменились ни на йоту, слияние не состоялось частично.
    ///
    /// Возврат РП (приёмка #137, голова 689f312): двух проверок хранилища недостаточно —
    /// добавлены (1) `assertNoChangeArrives` на `hub.changes()`, доказывающее, что `.deleted`
    /// не публикуется при отказе (без неё тест остался бы зелёным, даже переедь `emit(.deleted)`
    /// раньше `save`), и (2) проверка по `callLog`, что вызван именно `save(_:absorbing:)`
    /// с `[loserId]`, а не какой-то другой метод/аргумент.
    func test_k19_saveAbsorbingFailureLeavesBothRecordsUntouched() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        let sharedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let winnerId = Self.idLow
        let loserId = Self.idHigh

        try seedCollisionCandidateX(harness, id: winnerId, start: sharedStart)
        try seedCollisionCandidateY(harness, id: loserId, start: sharedStart.addingTimeInterval(3_600))
        harness.meetingRepository.fail(with: .io(message: "диск недоступен"), on: .save, id: winnerId.uuidString)

        let iterator = StreamIteratorBox(harness.hub.changes())
        let colliding = try mergeTestPayload(
            connectorId: "src-2", externalId: "evt-2", lastModified: sharedStart.addingTimeInterval(20),
            location: "Room-New"
        )
        do {
            _ = try await harness.hub.applyIncoming(payload: colliding)
            XCTFail("ожидался отказ save(_:absorbing:)")
        } catch {
            // ожидаемо — StorageError.io, настроенный выше.
        }

        await assertNoChangeArrives(iterator, "отказ save(_:absorbing:) не должен публиковать .deleted")

        let absorbingCall = harness.meetingRepository.callLog.calls(port: "MeetingRepository")
            .last { $0.method == "save(_:absorbing:)" }
        XCTAssertEqual(
            absorbingCall?.arguments, [winnerId.uuidString, loserId.uuidString],
            "mergeIncoming обязан звать save(_:absorbing:) с победителем и [loserId], не delete()+save()"
        )

        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 2, "отказ save(_:absorbing:) не удалил ни одной записи")
        let winnerAfter = stored.first { $0.event.id == winnerId }
        let loserAfter = stored.first { $0.event.id == loserId }
        XCTAssertEqual(winnerAfter?.sources.count, 1, "источники победителя не слиты — отказ до commit")
        XCTAssertEqual(loserAfter?.sources.count, 1, "проигравшая запись цела, со своим источником")
        XCTAssertEqual(winnerAfter?.event.location, "Room-X", "победитель не перезаписан слиянием")
    }

    private static func runCollision(idX: UUID, idY: UUID) async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        let sharedStart = Date(timeIntervalSince1970: 1_700_000_000)
        let winnerId = idX.uuidString < idY.uuidString ? idX : idY
        let loserId = idX.uuidString < idY.uuidString ? idY : idX

        try seedCollisionCandidateX(harness, id: idX, start: sharedStart)
        try seedCollisionCandidateY(harness, id: idY, start: sharedStart.addingTimeInterval(3_600))

        // Входящий payload сообщает пару Y (src-2/evt-2), но с icalUid и стартом X — признак
        // (а) находит X (по dedupKey), признак (б) — Y (по паре этого же payload'а).
        let iterator = StreamIteratorBox(harness.hub.changes())
        let colliding = try mergeTestPayload(
            connectorId: "src-2", externalId: "evt-2", lastModified: sharedStart.addingTimeInterval(20),
            location: "Room-New"
        )
        let saved = try await harness.hub.applyIncoming(payload: colliding)
        XCTAssertTrue(saved)

        let deleted = await nextOrTimeout(iterator)
        guard case .deleted(let ids) = deleted else {
            XCTFail(".deleted обязан публиковаться для поглощённой (проигравшей) записи — К39 вход А")
            return
        }
        XCTAssertEqual(ids, [loserId])

        let upserted = await nextOrTimeout(iterator)
        guard case .upserted(let events) = upserted else {
            XCTFail(".deleted обязан сопровождаться .upserted слитой записи сразу следующим элементом потока")
            return
        }
        XCTAssertEqual(events.first?.id, winnerId, ".upserted идёт СРАЗУ за .deleted, не вперемешку")

        let stored = harness.meetingRepository.storedRecords
        XCTAssertEqual(stored.count, 1, "проигравшая запись поглощена — осталась одна")
        XCTAssertEqual(stored.first?.event.id, winnerId, "побеждает лексикографически меньший id.uuidString")
        XCTAssertEqual(stored.first?.sources.count, 2, "источники проигравшей перешли победителю")
        XCTAssertTrue(
            stored.first?.sources.contains { $0.sourceConnectorId == "src-1" && $0.externalId == "evt-1" } ?? false,
            "источник X сохранён"
        )
        XCTAssertTrue(
            stored.first?.sources.contains { $0.sourceConnectorId == "src-2" && $0.externalId == "evt-2" } ?? false,
            "источник Y (обновлённый входящим payload'ом) сохранён"
        )
    }
}

/// Кандидат X — единственный источник src-1/evt-1, с `icalUid` "shared-uid" (совпадёт с
/// признаком (а) входящего payload'а теста). Вынесено свободной функцией — SwiftLint
/// `function_body_length` (предел 50 строк) считает только код самого теста.
private func seedCollisionCandidateX(_ harness: Harness, id: UUID, start: Date) throws {
    let payload = try mergeTestPayload(
        connectorId: "src-1", externalId: "evt-1", lastModified: start, location: "Room-X"
    )
    let event = try MeetingEvent(
        id: id, sourceConnectorId: "src-1", externalId: "evt-1", icalUid: "shared-uid", title: "T",
        start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
        isCancelled: false, organizer: nil, attendees: [], location: "Room-X", bodyText: nil, conference: nil,
        lastModified: start
    )
    harness.meetingRepository.seed([
        MeetingRecord(
            event: event, dedupKey: DedupKey.make(from: event), status: .ready,
            sources: [
                MeetingSource(
                    sourceConnectorId: "src-1", externalId: "evt-1", icalUid: "shared-uid",
                    lastModified: start, payload: payload
                )
            ]
        )
    ])
}

/// Кандидат Y — единственный источник src-2/evt-2, БЕЗ `icalUid` (`dedupKey` — `nil`),
/// семантически не связан с X до входящего payload'а теста.
private func seedCollisionCandidateY(_ harness: Harness, id: UUID, start: Date) throws {
    let payload = try MeetingEventPayload(
        sourceConnectorId: "src-2", externalId: "evt-2", icalUid: nil, title: "T",
        start: start, end: start.addingTimeInterval(1_800), timeZone: "UTC", isAllDay: false,
        isCancelled: false, organizer: nil, attendees: [], location: "Room-Y", bodyText: nil, conference: nil,
        lastModified: start
    )
    let event = try payload.assigningId(id)
    harness.meetingRepository.seed([
        MeetingRecord(
            event: event, dedupKey: DedupKey.make(from: event), status: .ready,
            sources: [
                MeetingSource(
                    sourceConnectorId: "src-2", externalId: "evt-2", icalUid: nil, lastModified: start, payload: payload
                )
            ]
        )
    ])
}
