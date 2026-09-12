//  MeetingEvent — DTO контракта C-001.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Нормализация — обязанность хоста, не DTO: ни один инвариант здесь ничего не чинит молча.
//  Нарушен инвариант — ошибка, экземпляр не создаётся.

import Foundation

/// Событие календаря, приведённое хостом к инвариантам C-001.
public struct MeetingEvent: Codable, Equatable, Sendable, DomainValidatable {

    public let id: UUID
    public let sourceConnectorId: String
    public let externalId: String
    public let icalUid: String?
    public let title: String
    public let start: Date
    public let end: Date
    public let timeZone: String
    public let isAllDay: Bool
    public let isCancelled: Bool
    public let organizer: Person?
    public let attendees: [Attendee]
    public let location: String?
    public let bodyText: String?
    public let conference: Conference?
    public let lastModified: Date

    public init(
        id: UUID,
        sourceConnectorId: String,
        externalId: String,
        icalUid: String?,
        title: String,
        start: Date,
        end: Date,
        timeZone: String,
        isAllDay: Bool,
        isCancelled: Bool,
        organizer: Person?,
        attendees: [Attendee],
        location: String?,
        bodyText: String?,
        conference: Conference?,
        lastModified: Date
    ) throws {
        self.id = id
        self.sourceConnectorId = sourceConnectorId
        self.externalId = externalId
        self.icalUid = icalUid
        self.title = title
        self.start = start
        self.end = end
        self.timeZone = timeZone
        self.isAllDay = isAllDay
        self.isCancelled = isCancelled
        self.organizer = organizer
        self.attendees = attendees
        self.location = location
        self.bodyText = bodyText
        self.conference = conference
        self.lastModified = lastModified
        try validate()
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceConnectorId, externalId, icalUid, title, start, end, timeZone
        case isAllDay, isCancelled, organizer, attendees, location, bodyText, conference
        case lastModified
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        id = try box.decode(UUID.self, forKey: .id)
        sourceConnectorId = try box.decode(String.self, forKey: .sourceConnectorId)
        externalId = try box.decode(String.self, forKey: .externalId)
        icalUid = try box.decodeIfPresent(String.self, forKey: .icalUid)
        title = try box.decode(String.self, forKey: .title)
        start = try box.decode(Date.self, forKey: .start)
        end = try box.decode(Date.self, forKey: .end)
        timeZone = try box.decode(String.self, forKey: .timeZone)
        isAllDay = try box.decode(Bool.self, forKey: .isAllDay)
        isCancelled = try box.decode(Bool.self, forKey: .isCancelled)
        organizer = try box.decodeIfPresent(Person.self, forKey: .organizer)
        attendees = try box.decode([Attendee].self, forKey: .attendees)
        location = try box.decodeIfPresent(String.self, forKey: .location)
        bodyText = try box.decodeIfPresent(String.self, forKey: .bodyText)
        conference = try box.decodeIfPresent(Conference.self, forKey: .conference)
        lastModified = try box.decode(Date.self, forKey: .lastModified)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        try box.encode(id, forKey: .id)
        try box.encode(sourceConnectorId, forKey: .sourceConnectorId)
        try box.encode(externalId, forKey: .externalId)
        try box.encodeIfPresent(icalUid, forKey: .icalUid)
        try box.encode(title, forKey: .title)
        try box.encode(start, forKey: .start)
        try box.encode(end, forKey: .end)
        try box.encode(timeZone, forKey: .timeZone)
        try box.encode(isAllDay, forKey: .isAllDay)
        try box.encode(isCancelled, forKey: .isCancelled)
        try box.encodeIfPresent(organizer, forKey: .organizer)
        try box.encode(attendees, forKey: .attendees)
        try box.encodeIfPresent(location, forKey: .location)
        try box.encodeIfPresent(bodyText, forKey: .bodyText)
        try box.encodeIfPresent(conference, forKey: .conference)
        try box.encode(lastModified, forKey: .lastModified)
    }

    /// Ступени §0.2 п. 6: (а) вложенные значения → (в) представимость → (б) собственные инварианты.
    public func validate() throws {
        let owner = DomainOwner(contract: "C-001", type: "MeetingEvent")
        try validateNested()
        try owner.requireDate(start, "start")
        try owner.requireDate(end, "end")
        try owner.requireDate(lastModified, "lastModified")
        try owner.check(end >= start, 1, "end", "end раньше start")
        try owner.check(TimeZone(identifier: timeZone) != nil, 2, "timeZone",
                        "не идентификатор IANA: \(timeZone)")
        try validateUniqueAddresses(owner)
        try validateAllDayBounds(owner)
    }

    /// Ступень (а): по полям в порядке объявления, внутри массива по возрастанию индекса.
    private func validateNested() throws {
        try organizer?.validate()
        for attendee in attendees {
            try attendee.validate()
        }
        try conference?.validate()
    }

    /// Инвариант 4: нарушителем является пара одинаковых адресов, а не элемент, — `path` есть
    /// имя коллекции (§0.1, правило 3). Элементы с `email == nil` не сравниваются друг с другом.
    private func validateUniqueAddresses(_ owner: DomainOwner) throws {
        var seen = Set<String>()
        for attendee in attendees {
            guard let email = attendee.person.email else { continue }
            guard seen.insert(email).inserted else {
                throw owner.fail(4, "attendees", "адрес \(email) встречается у двух участников")
            }
        }
    }

    /// Инвариант 7. Проверка записана через `startOfDay`, а не через компоненты: в сутки
    /// перехода на летнее время локального `00:00:00` не существует вовсе, и компонентное
    /// прочтение отвергло бы событие, которое хост построил по правилам этого же контракта.
    private func validateAllDayBounds(_ owner: DomainOwner) throws {
        guard isAllDay, let zone = TimeZone(identifier: timeZone) else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        try owner.check(calendar.startOfDay(for: start) == start, 7, "start",
                        "start не первое мгновение суток в поясе события")
        try owner.check(calendar.startOfDay(for: end) == end, 7, "end",
                        "end не первое мгновение суток в поясе события")
        try owner.check(end > start, 7, "end", "end не больше start у события на весь день")
    }
}
