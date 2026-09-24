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
    func test_k35_inputA_secondConcurrentManualSyncForSameSourceSharesInFlightResult() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        harness.connector("src-1").setFetchEvents([])
        harness.connector("src-1").hang(.fetchEvents)

        let first = Task { await harness.hub.sync(trigger: .manual) }
        await pollUntil { harness.connector("src-1").callCount(.fetchEvents) > 0 }
        let second = Task { await harness.hub.sync(trigger: .manual) }
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
    /// нескольких источников (внутри — параллельные `syncOne`, Р7), и, пока источник №2 ещё
    /// синхронизируется, для него же приходит `push` и вызывает `syncOne(source: №2,
    /// trigger: .push)` напрямую. Ответ: тот же принцип — прямой вызов не заводит вторую
    /// синхронизацию, делит результат уже идущей.
    func test_k35_inputB_directSyncOneDuringScheduleSyncSharesSameTask() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1", "src-2"])
        harness.connector("src-1").setFetchEvents([])
        harness.connector("src-2").setFetchEvents([])
        harness.connector("src-2").hang(.fetchEvents)

        let scheduled = Task { await harness.hub.sync(trigger: .schedule) }
        await pollUntil { harness.connector("src-2").callCount(.fetchEvents) > 0 }
        let pushed = Task {
            await harness.hub.syncOne(source: CalendarSourceId(rawValue: "src-2"), trigger: .push)
        }
        harness.connector("src-2").release(.fetchEvents)

        let scheduledResults = await scheduled.value
        let pushedResult = await pushed.value

        XCTAssertEqual(
            harness.connector("src-2").callCount(.fetchEvents), 1, "прямой syncOne не завёл вторую синхронизацию"
        )
        let scheduledSrc2 = scheduledResults.first { $0.sourceId == CalendarSourceId(rawValue: "src-2") }
        XCTAssertEqual(scheduledSrc2?.upsertedCount, pushedResult.upsertedCount)
        XCTAssertEqual(scheduledSrc2?.failure, pushedResult.failure)
    }
}
