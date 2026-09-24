//  MEE-290: управляющая поверхность `DomainTestKit.FakeCalendarPort`, названная
//  §«Фейк для тестов» C-005 дословно.
//
//  Граней четыре, и все четыре взяты у контракта, а не выдуманы: задать набор событий НА
//  ИСТОЧНИК; заставить `sync` вернуть заданный `CalendarError` для ВЫБРАННОГО источника;
//  вручную протолкнуть `CalendarChange` в поток `changes()`; посчитать число вызовов `sync`
//  ПО ТРИГГЕРАМ.
//
//  ГРАНИЦА НАЗВАНА: ни одно утверждение этого файла не говорит о поведении ПОРТА. Инварианты
//  1—9 C-005 — обязанность `calendar-hub`, и фейк их не исполняет: он не дедуплицирует
//  (`DedupKey.make(from:)` в дереве нет, её держит П4) и не сортирует ответ `events(from:to:)`.
//  Отсутствие сортировки проверяется здесь ПРЯМО — иначе следующий читатель примет её за
//  случайность и обопрётся на порядок порта.
//
//  Поток берётся ДО толчка — тот же довод и тот же образец, что у `FakePowerPortTests`.

import XCTest
import DomainCore
import DomainTestKit

final class FakeCalendarPortTests: XCTestCase {

    private let eventKit = CalendarSourceId(rawValue: "eventkit")
    private let graph = CalendarSourceId(rawValue: "graph:work")

    // MARK: - (а) набор событий задаётся НА ИСТОЧНИК

    func test_mee290_fakeCalendarPort_eventsAreSetPerSource() async throws {
        let port = FakeCalendarPort()
        port.setEvents([MeetingEventFixtures.oneOnOneZoom], for: eventKit)
        port.setEvents([MeetingEventFixtures.withoutConference], for: graph)

        let sources = await port.listSources()
        XCTAssertEqual(sources.map(\.rawValue), ["eventkit", "graph:work"], "источник заводится заданием событий")

        let all = try await port.events(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4e9))
        XCTAssertEqual(all.count, 2, "вектор непустоты: в окно попали оба события, а не ноль")
        XCTAssertEqual(
            all.map(\.id),
            [MeetingEventFixtures.oneOnOneZoom.id, MeetingEventFixtures.withoutConference.id],
            "порядок — заданный тестом, по источникам"
        )
    }

    /// Окно полуоткрыто справа и читается по `start`. Обе границы подаются точно.
    func test_mee290_fakeCalendarPort_windowIsHalfOpenOnStart() async throws {
        let port = FakeCalendarPort()
        let event = MeetingEventFixtures.oneOnOneZoom
        port.setEvents([event], for: eventKit)

        let inclusive = try await port.events(from: event.start, to: event.start.addingTimeInterval(1))
        XCTAssertEqual(inclusive.map(\.id), [event.id], "левая граница включена")

        let exclusive = try await port.events(from: event.start.addingTimeInterval(-1), to: event.start)
        XCTAssertEqual(exclusive, [], "правая граница исключена")
    }

    /// Фейк не сортирует: события уходят в том порядке, в каком их задали.
    func test_mee290_fakeCalendarPort_doesNotSortEvents() async throws {
        let port = FakeCalendarPort()
        let zoom = MeetingEventFixtures.oneOnOneZoom
        let planning = MeetingEventFixtures.duplicateFromEventKit
        XCTAssertNotEqual(zoom.start, planning.start, "вектор непустоты: события различимы по start")

        // Задаём заведомо ПО УБЫВАНИЮ `start` — то есть не так, как велит инвариант 6.
        let ordered = zoom.start < planning.start ? [planning, zoom] : [zoom, planning]
        port.setEvents(ordered, for: eventKit)

        let answer = try await port.events(from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4e9))
        XCTAssertEqual(answer.map(\.id), ordered.map(\.id),
                       "порядок входа сохранён — инвариант 6 фейком не исполняется")
    }

    // MARK: - (б) `sync` отказывает на ВЫБРАННОМ источнике

    func test_mee290_fakeCalendarPort_syncFailsOnlyOnChosenSource() async {
        let port = FakeCalendarPort()
        port.setEvents([MeetingEventFixtures.oneOnOneZoom], for: eventKit)
        port.setEvents([MeetingEventFixtures.withoutConference], for: graph)
        port.failSync(with: CalendarError.authorizationRequired(sourceId: graph), for: graph)

        let results = await port.sync(trigger: .manual)
        XCTAssertEqual(results.count, 2, "вектор непустоты: по результату на источник")
        let failed = results.filter { $0.failure != nil }
        XCTAssertEqual(failed.map(\.sourceId.rawValue), ["graph:work"], "отказ ровно у выбранного")
        let observed: CalendarError? = failed.first?.failure
        let expected = CalendarError.authorizationRequired(sourceId: graph)
        XCTAssertEqual(observed, expected, "ошибка та, что задали")
        XCTAssertEqual(results.first(where: { $0.sourceId.rawValue == "eventkit" })?.upsertedCount, 1)
        XCTAssertEqual(failed.first?.upsertedCount, 0, "отказавший источник ничего не влил")
    }

    func test_mee290_fakeCalendarPort_syncMomentIsGivenByTest() async {
        let port = FakeCalendarPort()
        port.setEvents([], for: eventKit)
        let moment = Date(timeIntervalSince1970: 1_789_000_000)
        port.setSyncMoment(moment)

        let results = await port.sync(trigger: .wake)
        XCTAssertEqual(results.count, 1, "вектор непустоты")
        XCTAssertEqual(results.first?.startedAt, moment)
        XCTAssertEqual(results.first?.finishedAt, moment)
    }

    // MARK: - (в) счёт вызовов `sync` ПО ТРИГГЕРАМ

    func test_mee290_fakeCalendarPort_countsSyncCallsByTrigger() async {
        let port = FakeCalendarPort()
        port.setEvents([], for: eventKit)

        // Вектор непустоты: до вызовов все счётчики нулевые, и равенство ниже без вызовов
        // было бы зелено по построению.
        for trigger in [CalendarSyncTrigger.schedule, .wake, .manual, .push] {
            XCTAssertEqual(port.syncCallCount(trigger: trigger), 0, "\(trigger.rawValue) до вызовов")
        }

        _ = await port.sync(trigger: .manual)
        _ = await port.sync(trigger: .manual)
        _ = await port.sync(trigger: .wake)

        XCTAssertEqual(port.syncCallCount(trigger: .manual), 2)
        XCTAssertEqual(port.syncCallCount(trigger: .wake), 1)
        XCTAssertEqual(port.syncCallCount(trigger: .schedule), 0, "чужой триггер не растёт")
        XCTAssertEqual(port.syncCallCount(trigger: .push), 0)
        XCTAssertEqual(port.syncCallCount, 3, "сумма по всем триггерам")
    }

    // MARK: - (г) любой `CalendarChange` в поток

    func test_mee290_fakeCalendarPort_pushesAnyChangeIntoStream() async {
        let port = FakeCalendarPort()
        let stream = port.changes()          // поток берётся ДО толчка
        let pushed: [CalendarChange] = [
            .upserted([MeetingEventFixtures.oneOnOneZoom]),
            .deleted([MeetingEventFixtures.withoutConference.id]),
            .upserted([])                    // пустая пачка — значение не приводится ни к чему
        ]
        for change in pushed {
            port.emit(change)
        }
        port.finishChanges()

        var seen: [CalendarChange] = []
        for await change in stream {
            seen.append(change)
        }
        XCTAssertEqual(seen.count, 3, "вектор непустоты: поток не пуст и не обрезан")
        XCTAssertEqual(seen, pushed, "значения доходят как есть и в порядке толчка")
    }

    func test_mee290_fakeCalendarPort_selectedCalendarsAreObservable() async throws {
        let port = FakeCalendarPort()
        XCTAssertNil(port.selectedCalendars(for: eventKit), "до вызова выбора нет")
        try await port.setSelectedCalendars(source: eventKit, calendarIds: ["work", "home"])
        XCTAssertEqual(port.selectedCalendars(for: eventKit), ["work", "home"])
        XCTAssertNil(port.selectedCalendars(for: graph), "чужой источник не тронут")
    }
}
