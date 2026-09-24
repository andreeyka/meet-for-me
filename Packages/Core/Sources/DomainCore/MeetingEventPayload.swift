//  MeetingEventPayload — тип полезной нагрузки коннектора, C-006 §6.1.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ОБЪЯВЛЕН В `domain-core`, ХОТЯ ВЛАДЕЕТ ИМ C-006, А НЕ C-001 — ЭТО НАЗВАНО КОНТРАКТОМ
//  ПРЯМО (§6.1: «Объявлен в domain-core, владелец объявления — этот контракт»). Отвечает
//  ошибкой `contract == "C-001"`, а не `"C-006"`: причина в `MeetingEventValidation.swift`.
//
//  ВЛОЖЕННЫЕ ТИПЫ НЕ ПЕРЕОБЪЯВЛЯЮТСЯ. `MeetingEvent.Person`, `.Attendee`, `.Conference`
//  берутся как есть — копия дала бы два списка инвариантов на один и тот же адрес
//  электронной почты, и разошлись бы они на первой правке (§6.1 дословно).

import Foundation

/// Событие календаря в том виде, в каком его отдаёт коннектор: все поля `MeetingEvent`
/// (C-001), кроме `id`. `id` назначает хост и только хост (`assigningId(_:)`).
public struct MeetingEventPayload: Codable, Equatable, Sendable, DomainValidatable {

    public let sourceConnectorId: String
    public let externalId: String
    public let icalUid: String?
    public let title: String
    public let start: Date
    public let end: Date
    public let timeZone: String
    public let isAllDay: Bool
    public let isCancelled: Bool
    public let organizer: MeetingEvent.Person?
    public let attendees: [MeetingEvent.Attendee]
    public let location: String?
    public let bodyText: String?
    public let conference: MeetingEvent.Conference?
    public let lastModified: Date

    /// Единственный способ собрать значение в коде. Заканчивается `try validate()`.
    public init(
        sourceConnectorId: String,
        externalId: String,
        icalUid: String?,
        title: String,
        start: Date,
        end: Date,
        timeZone: String,
        isAllDay: Bool,
        isCancelled: Bool,
        organizer: MeetingEvent.Person?,
        attendees: [MeetingEvent.Attendee],
        location: String?,
        bodyText: String?,
        conference: MeetingEvent.Conference?,
        lastModified: Date
    ) throws {
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

    /// Снять `id` с готового события. НЕ БРОСАЕТ: каждый инвариант полезной нагрузки —
    /// инвариант источника (`MeetingEvent`), уже проверенный при его создании, и «вычитание
    /// пустое» — ни один из семи не ссылается на `id` (§6.1).
    public init(dropping event: MeetingEvent) {
        sourceConnectorId = event.sourceConnectorId
        externalId = event.externalId
        icalUid = event.icalUid
        title = event.title
        start = event.start
        end = event.end
        timeZone = event.timeZone
        isAllDay = event.isAllDay
        isCancelled = event.isCancelled
        organizer = event.organizer
        attendees = event.attendees
        location = event.location
        bodyText = event.bodyText
        conference = event.conference
        lastModified = event.lastModified
    }

    /// Присвоить `id`. Операция хоста; коннектору вызывать её нечем и незачем (§6.1,
    /// «Поведение»). Проверка здесь избыточна по построению (см. `init(dropping:)`), но
    /// не снимается: `MeetingEvent.init` кончается `try validate()` по C-001 §0.2 п. 3, и
    /// обходить его значило бы пробить контракт ради одного лишнего прохода по `attendees`.
    public func assigningId(_ id: UUID) throws -> MeetingEvent {
        try MeetingEvent(
            id: id, sourceConnectorId: sourceConnectorId, externalId: externalId,
            icalUid: icalUid, title: title, start: start, end: end, timeZone: timeZone,
            isAllDay: isAllDay, isCancelled: isCancelled, organizer: organizer,
            attendees: attendees, location: location, bodyText: bodyText,
            conference: conference, lastModified: lastModified
        )
    }

    /// Все ключи полезной нагрузки, ПЛЮС `id` — только чтобы поймать инвариант 15 (ключ
    /// `id` в объекте полезной нагрузки есть отказ разбора). В самом типе поля `id` нет.
    private enum CodingKeys: String, CodingKey {
        case id
        case sourceConnectorId, externalId, icalUid, title, start, end, timeZone
        case isAllDay, isCancelled, organizer, attendees, location, bodyText, conference
        case lastModified
    }

    /// Инвариант 15 (C-006 §6): ключ `id` проверяется ДО остальных полей и даёт
    /// `DecodingError.dataCorrupted` с `id` в `codingPath` — названное исключение из
    /// правила «неизвестные ключи игнорируются» (C-001 §0.4).
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        guard !box.contains(.id) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: box.codingPath + [CodingKeys.id],
                debugDescription: "MeetingEventPayload не несёт id: назначает его хост (C-006 §6.1)"
            ))
        }
        sourceConnectorId = try box.decode(String.self, forKey: .sourceConnectorId)
        externalId = try box.decode(String.self, forKey: .externalId)
        icalUid = try box.decodeIfPresent(String.self, forKey: .icalUid)
        title = try box.decode(String.self, forKey: .title)
        start = try box.decode(Date.self, forKey: .start)
        end = try box.decode(Date.self, forKey: .end)
        timeZone = try box.decode(String.self, forKey: .timeZone)
        isAllDay = try box.decode(Bool.self, forKey: .isAllDay)
        isCancelled = try box.decode(Bool.self, forKey: .isCancelled)
        organizer = try box.decodeIfPresent(MeetingEvent.Person.self, forKey: .organizer)
        attendees = try box.decode([MeetingEvent.Attendee].self, forKey: .attendees)
        location = try box.decodeIfPresent(String.self, forKey: .location)
        bodyText = try box.decodeIfPresent(String.self, forKey: .bodyText)
        conference = try box.decodeIfPresent(MeetingEvent.Conference.self, forKey: .conference)
        lastModified = try box.decode(Date.self, forKey: .lastModified)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
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

    /// Общая функция `MeetingEventValidation` — тот же список инвариантов, что у
    /// `MeetingEvent`, той же функцией, а не второй её копией (C-006 §6.1).
    public func validate() throws {
        try MeetingEventValidation.validate(
            owner: DomainOwner(contract: "C-001", type: "MeetingEventPayload"),
            start: start, end: end, lastModified: lastModified, timeZone: timeZone,
            isAllDay: isAllDay, organizer: organizer, attendees: attendees, conference: conference
        )
    }
}
