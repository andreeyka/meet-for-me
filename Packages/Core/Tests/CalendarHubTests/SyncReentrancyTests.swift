//  К35 (C-005 «Поведение», п.1 — sync не реентерантна в пределах источника, расширено на
//  syncOne): вход А — второй параллельный sync(trigger:) для того же источника получает
//  результат уже идущего, не запускает второй; вход Б — прямой syncOne(source:trigger:)
//  (push-путь) во время идущего sync(trigger:) для того же источника делит ту же задачу.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class SyncReentrancyTests: XCTestCase {

    /// Вход А: `sync(trigger: .manual)` вызван повторно для того же источника, пока первый
    /// вызов не завершился. Ответ: второй вызов не запускает вторую синхронизацию —
    /// возвращает результат текущей; счётчик обращений к `connector.fetchEvents` за оба
    /// вызова — один.
    ///
    /// Возврат РП (приёмка #128, п. 3): без ожидания `syncWaiters[source]?.count == 2`
    /// между стартом `second` и `release(.fetchEvents)` возможна гонка — `second` мог не
    /// успеть дойти до регистрации в `syncWaiters` (`awaitSharedSync`) к моменту, когда
    /// `hangOrGate` уже отпущен и общая задача завершается: `finishInFlightSync` рассылает
    /// результат только УЖЕ зарегистрированным ожидающим, опоздавший повис бы навсегда.
    func test_k35_inputA_secondConcurrentManualSyncForSameSourceSharesInFlightResult() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        let sourceId = CalendarSourceId(rawValue: "src-1")
        harness.connector("src-1").setFetchEvents([])
        harness.connector("src-1").hang(.fetchEvents)

        let first = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil { harness.connector("src-1").callCount(.fetchEvents) > 0 }
        let second = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil { await harness.hub.syncWaiters[sourceId]?.count == 2 }
        harness.connector("src-1").release(.fetchEvents)

        let firstResults = await first.value
        let secondResults = await second.value

        XCTAssertEqual(
            harness.connector("src-1").callCount(.fetchEvents), 1, "второй вызов не завёл свою синхронизацию"
        )
        XCTAssertEqual(firstResults.first?.upsertedCount, secondResults.first?.upsertedCount)
        XCTAssertEqual(firstResults.first?.failure, secondResults.first?.failure)
    }

    /// Вход Б (сочетание с внутренней `syncOne`, Р6): `sync(trigger: .schedule)` идёт для
    /// ТРЁХ источников (буквально по тексту К35, не двух), внутри — параллельные `syncOne`
    /// (Р7), и, пока источник №2 ещё синхронизируется, для него же приходит `push` и
    /// вызывает `syncOne(source: №2, trigger: .push)` напрямую. Ответ: тот же принцип —
    /// прямой вызов не заводит вторую синхронизацию, делит результат уже идущей; источники
    /// №1 и №3 при этом не затронуты — синхронизируются независимо, пока №2 висит.
    func test_k35_inputB_directSyncOneDuringScheduleSyncSharesSameTaskThreeSources() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2", "src-3"])
        let source2 = CalendarSourceId(rawValue: "src-2")
        harness.connector("src-1").setFetchEvents([])
        harness.connector("src-2").setFetchEvents([])
        harness.connector("src-3").setFetchEvents([])
        harness.connector("src-2").hang(.fetchEvents)

        let scheduled = Task { await harness.hub.sync(trigger: .schedule) }
        await pollUntil { harness.connector("src-2").callCount(.fetchEvents) > 0 }
        let pushed = Task { await harness.hub.syncOne(source: source2, trigger: .push) }
        await pollUntil { await harness.hub.syncWaiters[source2]?.count == 2 }
        harness.connector("src-2").release(.fetchEvents)

        let scheduledResults = await scheduled.value
        let pushedResult = await pushed.value

        XCTAssertEqual(
            harness.connector("src-2").callCount(.fetchEvents), 1, "прямой syncOne не завёл вторую синхронизацию"
        )
        let scheduledSrc2 = scheduledResults.first { $0.sourceId == source2 }
        XCTAssertEqual(scheduledSrc2?.upsertedCount, pushedResult.upsertedCount)
        XCTAssertEqual(scheduledSrc2?.failure, pushedResult.failure)

        // Источники №1/№3 не затронуты — успели синхронизироваться независимо, пока №2 висел.
        let src1Result = scheduledResults.first { $0.sourceId == CalendarSourceId(rawValue: "src-1") }
        let src3Result = scheduledResults.first { $0.sourceId == CalendarSourceId(rawValue: "src-3") }
        XCTAssertNil(src1Result?.failure)
        XCTAssertNil(src3Result?.failure)
        XCTAssertEqual(harness.connector("src-1").callCount(.fetchEvents), 1)
        XCTAssertEqual(harness.connector("src-3").callCount(.fetchEvents), 1)
    }
}
