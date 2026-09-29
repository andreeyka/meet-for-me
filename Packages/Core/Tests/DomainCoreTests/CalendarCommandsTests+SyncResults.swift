//  CalendarCommandsTests — добор К39 по сверке покрытия MEE-401 (`484179e8`), MEE-448:
//  `syncCalendars()` отдаёт `[CalendarSyncResult]` порта без изменений. Раньше у этого метода
//  проверялись только события (`EventsTests.swift`). Тот же класс, `makeFixture()` —
//  из `CalendarCommandsTests.swift`.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension CalendarCommandsTests {

    // MARK: - К39: syncCalendars — смешанный набор CalendarSyncResult насквозь

    /// Вход К39 дословно: фейк `CalendarPort` отдаёт смешанный набор — источник с
    /// событиями, источник с отказом, пустой источник. Ответ — ровно этот набор, в том же
    /// порядке, каждое поле без изменения (включая `failure` и моменты), и один вызов
    /// `CalendarPort.sync`.
    func test_k39_syncCalendars_returnsMixedSyncResultsUnchanged() async {
        let fixture = makeFixture()
        let moment = Date(timeIntervalSince1970: 1_800_000_123)
        let withEvents = CalendarSourceId(rawValue: "eventkit")
        let failing = CalendarSourceId(rawValue: "graph")
        let empty = CalendarSourceId(rawValue: "ics")
        let failure = CalendarError.transport(sourceId: failing, message: "сеть недоступна")
        fixture.calendar.setSyncMoment(moment)
        fixture.calendar.setSources([withEvents, failing, empty])
        fixture.calendar.setEvents(
            [MeetingEventFixtures.oneOnOneZoom, MeetingEventFixtures.withoutConference], for: withEvents
        )
        fixture.calendar.setEvents([MeetingEventFixtures.cancelled], for: failing)
        fixture.calendar.failSync(with: failure, for: failing)

        let results = await fixture.facade.syncCalendars()

        let expected = [
            CalendarSyncResult(
                sourceId: withEvents, trigger: .manual, startedAt: moment, finishedAt: moment,
                upsertedCount: 2, deletedCount: 0, failure: nil
            ),
            CalendarSyncResult(
                sourceId: failing, trigger: .manual, startedAt: moment, finishedAt: moment,
                upsertedCount: 0, deletedCount: 0, failure: failure
            ),
            CalendarSyncResult(
                sourceId: empty, trigger: .manual, startedAt: moment, finishedAt: moment,
                upsertedCount: 0, deletedCount: 0, failure: nil
            )
        ]
        XCTAssertEqual(results, expected)
        XCTAssertEqual(fixture.calendar.syncCallCount, 1, "ровно один вызов CalendarPort.sync")
        XCTAssertEqual(fixture.calendar.syncCallCount(trigger: .manual), 1)
    }
}
