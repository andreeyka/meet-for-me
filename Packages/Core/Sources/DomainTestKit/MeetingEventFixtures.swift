//  Фикстуры C-001 — «Фейк для тестов» MeetingEvent.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки для тестов)
//
//  Фикстуры детерминированы: `Date()`, `UUID()` и генераторы случайных чисел здесь не
//  вызываются. Все отметки времени выровнены по целой секунде, поэтому круговое
//  преобразование по равенству они переживают.

import Foundation
import DomainCore

// Фикстура, не проходящая инварианты своего контракта, — дефект фикстуры, а не оснастки:
// её собирает тот же публичный инициализатор, что и продуктовый код, и падение здесь
// означает, что набор перестал значить то, что обещает.
// swiftlint:disable force_try

/// Набор событий календаря, покрывающий случаи раздела «Фейк для тестов» C-001.
public enum MeetingEventFixtures {

    /// Встреча 1:1 со ссылкой Zoom.
    public static let oneOnOneZoom: MeetingEvent = try! MeetingEvent(
        id: uuid("11111111-1111-4111-8111-111111111111"),
        sourceConnectorId: "eventkit",
        externalId: "evt-1001",
        icalUid: "ical-1001@example.com",
        title: "Синхронизация 1:1",
        start: Date(timeIntervalSince1970: 1_789_119_000),
        end: Date(timeIntervalSince1970: 1_789_120_800),
        timeZone: "Europe/Moscow",
        isAllDay: false,
        isCancelled: false,
        organizer: try! MeetingEvent.Person(name: "Андрей", email: "andrey@example.com"),
        attendees: [
            try! MeetingEvent.Attendee(
                person: try! MeetingEvent.Person(name: "Андрей", email: "andrey@example.com"),
                responseStatus: .accepted,
                isOptional: false
            ),
            try! MeetingEvent.Attendee(
                person: try! MeetingEvent.Person(name: "Мария", email: "maria@example.com"),
                responseStatus: .tentative,
                isOptional: false
            )
        ],
        location: "Zoom",
        bodyText: "Повестка: планы на неделю.",
        conference: try! MeetingEvent.Conference(
            provider: "zoom",
            joinUrl: url("https://zoom.us/j/1234567890"),
            meetingId: "1234567890",
            passcode: "042"
        ),
        lastModified: Date(timeIntervalSince1970: 1_789_041_600)
    )

    /// Встреча без `conference` и без организатора.
    public static let withoutConference: MeetingEvent = try! MeetingEvent(
        id: uuid("22222222-2222-4222-8222-222222222222"),
        sourceConnectorId: "eventkit",
        externalId: "evt-1002",
        icalUid: nil,
        title: "",
        start: Date(timeIntervalSince1970: 1_789_113_600),
        end: Date(timeIntervalSince1970: 1_789_117_200),
        timeZone: "UTC",
        isAllDay: false,
        isCancelled: false,
        organizer: nil,
        attendees: [],
        location: nil,
        bodyText: nil,
        conference: nil,
        lastModified: Date(timeIntervalSince1970: 1_789_041_600)
    )

    /// Отменённая встреча.
    public static let cancelled: MeetingEvent = try! MeetingEvent(
        id: uuid("33333333-3333-4333-8333-333333333333"),
        sourceConnectorId: "graph",
        externalId: "evt-1003",
        icalUid: "ical-1003@example.com",
        title: "Отменённый созвон",
        start: Date(timeIntervalSince1970: 1_789_119_000),
        end: Date(timeIntervalSince1970: 1_789_122_600),
        timeZone: "Europe/Moscow",
        isAllDay: false,
        isCancelled: true,
        organizer: try! MeetingEvent.Person(name: "Мария", email: "maria@example.com"),
        attendees: [],
        location: nil,
        bodyText: nil,
        conference: nil,
        lastModified: Date(timeIntervalSince1970: 1_789_041_600)
    )

    /// Два участника с одинаковым именем и разными адресами.
    public static let sameNameDifferentAddresses: MeetingEvent = try! MeetingEvent(
        id: uuid("44444444-4444-4444-8444-444444444444"),
        sourceConnectorId: "eventkit",
        externalId: "evt-1004",
        icalUid: "ical-1004@example.com",
        title: "Двое Иванов",
        start: Date(timeIntervalSince1970: 1_789_119_000),
        end: Date(timeIntervalSince1970: 1_789_120_800),
        timeZone: "Europe/Moscow",
        isAllDay: false,
        isCancelled: false,
        organizer: nil,
        attendees: [
            try! MeetingEvent.Attendee(
                person: try! MeetingEvent.Person(name: "Иван", email: "ivan@example.com"),
                responseStatus: .accepted,
                isOptional: false
            ),
            try! MeetingEvent.Attendee(
                person: try! MeetingEvent.Person(name: "Иван", email: "ivan.petrov@example.com"),
                responseStatus: .needsAction,
                isOptional: true
            )
        ],
        location: nil,
        bodyText: nil,
        conference: nil,
        lastModified: Date(timeIntervalSince1970: 1_789_041_600)
    )

    /// Первая половина пары «одно событие из двух источников»: источник EventKit.
    public static let duplicateFromEventKit: MeetingEvent = duplicate(
        id: "55555555-5555-4555-8555-555555555555",
        connector: "eventkit",
        externalId: "evt-2002-eventkit"
    )

    /// Вторая половина той же пары: источник Microsoft Graph. Различаются `id`,
    /// `sourceConnectorId` и `externalId`; совпадают непустой `icalUid` и `joinUrl`.
    public static let duplicateFromGraph: MeetingEvent = duplicate(
        id: "66666666-6666-4666-8666-666666666666",
        connector: "graph",
        externalId: "evt-2002-graph"
    )

    /// Событие на весь день: обе границы — первое мгновение суток в поясе события.
    public static let allDayMoscow: MeetingEvent = try! MeetingEvent(
        id: uuid("77777777-7777-4777-8777-777777777777"),
        sourceConnectorId: "eventkit",
        externalId: "evt-3001",
        icalUid: "ical-3001@example.com",
        title: "Выходной",
        start: Date(timeIntervalSince1970: 1_789_074_000),
        end: Date(timeIntervalSince1970: 1_789_160_400),
        timeZone: "Europe/Moscow",
        isAllDay: true,
        isCancelled: false,
        organizer: nil,
        attendees: [],
        location: nil,
        bodyText: nil,
        conference: nil,
        lastModified: Date(timeIntervalSince1970: 1_789_041_600)
    )

    /// Событие на весь день в сутки, где полуночи не существует: 29.03.2026 в Бейруте
    /// часы прыгают с 00:00 на 01:00. Реализация с компонентной проверкой краснеет здесь
    /// и остаётся зелёной на всех остальных фикстурах. `end - start` равен 23 часам.
    public static let allDayWithoutMidnight: MeetingEvent = try! MeetingEvent(
        id: uuid("88888888-8888-4888-8888-888888888888"),
        sourceConnectorId: "eventkit",
        externalId: "evt-3002",
        icalUid: "ical-3002@example.com",
        title: "Сутки без полуночи",
        start: Date(timeIntervalSince1970: 1_774_735_200),
        end: Date(timeIntervalSince1970: 1_774_818_000),
        timeZone: "Asia/Beirut",
        isAllDay: true,
        isCancelled: false,
        organizer: nil,
        attendees: [],
        location: nil,
        bodyText: nil,
        conference: nil,
        lastModified: Date(timeIntervalSince1970: 1_774_699_200)
    )

    /// Все фикстуры набора. Тесты обходят её циклом, а не перечисляют литералами.
    public static let allFixtures: [MeetingEvent] = [
        oneOnOneZoom,
        withoutConference,
        cancelled,
        sameNameDifferentAddresses,
        duplicateFromEventKit,
        duplicateFromGraph,
        allDayMoscow,
        allDayWithoutMidnight
    ]

    private static func duplicate(id: String, connector: String, externalId: String) -> MeetingEvent {
        try! MeetingEvent(
            id: uuid(id),
            sourceConnectorId: connector,
            externalId: externalId,
            icalUid: "ical-2002@example.com",
            title: "Планёрка",
            start: Date(timeIntervalSince1970: 1_789_196_400),
            end: Date(timeIntervalSince1970: 1_789_200_300),
            timeZone: "Europe/Moscow",
            isAllDay: false,
            isCancelled: false,
            organizer: try! MeetingEvent.Person(name: "Андрей", email: "andrey@example.com"),
            attendees: [],
            location: nil,
            bodyText: nil,
            conference: try! MeetingEvent.Conference(
                provider: "meet",
                joinUrl: url("https://meet.google.com/abc-defg-hij"),
                meetingId: nil,
                passcode: nil
            ),
            lastModified: Date(timeIntervalSince1970: 1_789_041_600)
        )
    }

    static func uuid(_ text: String) -> UUID {
        guard let value = UUID(uuidString: text) else {
            preconditionFailure("фикстура содержит негодный UUID: \(text)")
        }
        return value
    }

    static func url(_ text: String) -> URL {
        guard let value = URL(string: text) else {
            preconditionFailure("фикстура содержит негодный URL: \(text)")
        }
        return value
    }
}

// swiftlint:enable force_try
