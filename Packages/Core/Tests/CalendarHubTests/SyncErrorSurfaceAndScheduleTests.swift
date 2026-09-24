//  К42 (C-005 «Определение» — listCalendars/events/setSelectedCalendars бросают CalendarError,
//  не кладут его в поле результата, как делает sync), К43 (C-006 инв. 8 — resetRequired
//  заставляет следующую синхронизацию вызвать fetchEvents), К44 (развилка Р5 — таймер
//  расписания считает тики Ш3, не реальное время), К45 (.wake — обычный триггер, без отдельной
//  ветки кода).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import CalendarHub

final class SyncErrorSurfaceAndScheduleTests: XCTestCase {

    /// Вход: `connector.listCalendars()` бросает `ConnectorError.authorizationRequired`.
    /// Ответ: `CalendarPort.listCalendars(source:)` пробрасывает
    /// `CalendarError.authorizationRequired(sourceId:)` — не кладёт в поле результата, как
    /// делает `sync` (К34); `events`/`setSelectedCalendars` к коннектору не обращаются вовсе
    /// (репозиторий-only пути) — различающий вектор этого критерия воспроизводим только на
    /// `listCalendars`, том же примере, что называет сам текст критерия.
    func test_k42_listCalendarsThrowsCalendarErrorInsteadOfReturningItInAResult() async throws {
        let harness = Harness(sourceIds: ["src-1"])
        harness.connectorRepository.seed([Harness.record(id: "src-1")])
        harness.connector("src-1").setInitializeResult(capabilities: ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        ))
        harness.connector("src-1").fail(.listCalendars, with: .authorizationRequired)

        do {
            _ = try await harness.hub.listCalendars(source: CalendarSourceId(rawValue: "src-1"))
            XCTFail("authorizationRequired обязан пробрасываться, а не класться в поле результата")
        } catch let error as CalendarError {
            XCTAssertEqual(error, .authorizationRequired(sourceId: CalendarSourceId(rawValue: "src-1")))
        }
    }

    /// Вход: `fetchChanges` отвечает `resetRequired == true`. Ответ: следующая синхронизация
    /// этого источника вызывает `fetchEvents`, независимо от того, есть ли ещё годный курсор
    /// — не запрещает `fetchChanges` присутствовать в том же цикле (развилка Р9 всё равно
    /// начинает его с шага 1, `fetchAndApply`, `CalendarPortImplSync.swift`), лишь требует
    /// самого факта, что `fetchEvents` тоже вызывается.
    func test_k43_resetRequiredMakesNextSyncCallFetchEventsRegardlessOfCursorValidity() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"], deltaSync: true, cursor: "cursor-0")
        let connector = harness.connector("src-1")
        connector.setFetchChanges(
            ChangeBatch(events: [], deletedExternalIds: [], cursor: "ignored", resetRequired: true)
        )

        let firstResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(firstResults.first?.failure)
        XCTAssertNil(harness.connectorRepository.storedRecords.first?.cursor, "инв. 8 — курсор сброшен в nil")
        XCTAssertEqual(connector.callCount(.fetchEvents), 0, "на этом цикле fetchEvents ещё не вызван")

        connector.setFetchChanges(
            ChangeBatch(events: [], deletedExternalIds: [], cursor: "cursor-2", resetRequired: false)
        )
        connector.setFetchEvents([])

        let secondResults = await harness.hub.sync(trigger: .manual)
        XCTAssertNil(secondResults.first?.failure)
        XCTAssertEqual(connector.callCount(.fetchEvents), 1, "следующая синхронизация вызывает fetchEvents")
    }

    /// Запускает таймер `.schedule` каждые 15 минут через Ш3 — счётом тиков, без секунды
    /// реального времени в тесте. Три тика Ш3 — три вызова `sync(trigger: .schedule)`,
    /// каждый раз запросив у шва интервал `.seconds(15*60)`.
    func test_k44_scheduledPollingCallsScheduleSyncEveryFifteenMinutesByWaitSeamTicksNotWallClock() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        harness.connector("src-1").setFetchEvents([])

        await harness.hub.startScheduledPolling()
        for tick in 1...3 {
            await pollUntil { harness.waitSeam.resolveNext() }
            await pollUntil { harness.connector("src-1").callCount(.fetchEvents) == tick }
        }
        await harness.hub.stopScheduledPolling()

        XCTAssertEqual(
            harness.waitSeam.durations.filter { $0 == .seconds(15 * 60) }.count, 3,
            "интервал — счёт тиков Ш3 на .minutes(15), не измерение реального времени"
        )
    }

    /// Вход: внешний вызывающий код вызывает `sync(trigger: .wake)`. Ответ: `sync`
    /// обрабатывает `.wake` тем же путём, что и любой другой триггер — не заводит отдельной
    /// ветки кода; `CalendarSyncResult.trigger == .wake` в результате.
    func test_k45_wakeTriggerHandledTheSameWayAsAnyOtherTriggerNoSeparateBranch() async throws {
        let harness = Harness.mergeReady(sourceIds: ["src-1"])
        harness.connector("src-1").setFetchEvents([])

        let results = await harness.hub.sync(trigger: .wake)

        XCTAssertEqual(results.first?.trigger, .wake)
        XCTAssertNil(results.first?.failure)
        XCTAssertEqual(harness.connector("src-1").callCount(.fetchEvents), 1)
    }
}
