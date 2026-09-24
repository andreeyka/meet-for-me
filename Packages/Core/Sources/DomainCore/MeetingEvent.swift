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

    /// Ступени §0.2 п. 6: (а) вложенные значения → (в) представимость → (б) собственные
    /// инварианты — все три ступени идут общей функцией `MeetingEventValidation.validate`,
    /// которую вызывает и `MeetingEventPayload` (C-006 §6.1): список инвариантов 1, 2, 4, 6,
    /// 7 существует в одном экземпляре, а не по одному на каждый из двух типов.
    public func validate() throws {
        try MeetingEventValidation.validate(
            owner: DomainOwner(contract: "C-001", type: "MeetingEvent"),
            start: start, end: end, lastModified: lastModified, timeZone: timeZone,
            isAllDay: isAllDay, organizer: organizer, attendees: attendees, conference: conference
        )
    }
}
