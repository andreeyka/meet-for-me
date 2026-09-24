//  CalendarPortImpl+Merge+SourceDeparture — К65 вход А/Б (перечень MEE-347): источник
//  теряется у записи (удалён целиком, если был единственным; иначе пересчёт по инв. 10).
//  Вынесено отдельным файлом той же причиной, что развела `CalendarPortImplSync.swift`/
//  `CalendarPortImplMerge.swift`: SwiftLint `file_length`/`type_body_length` считают каждое
//  расширение типа отдельно.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import DomainCore

extension CalendarPortImpl {

    /// К65 вход Б — источник теряется у многоисточниковой встречи. Инв. 11: идёт через ту
    /// же общую цепочку `serialized`, что `applyIncoming` — эта операция тоже переустраивает
    /// `sources`/`event` встречи, конкурентная гонка с `applyIncoming` того же дедуп-ключа
    /// иначе возможна (возврат РП, приёмка #105, п. 2 — «все слияния», не только входящие).
    func applyDeletedExternalId(source: CalendarSourceId, externalId: String) async throws -> Bool {
        try await serialized {
            try await self.removeExternalId(source: source, externalId: externalId)
        }
    }

    private func removeExternalId(source: CalendarSourceId, externalId: String) async throws -> Bool {
        guard let record = try await meetingRepository.meeting(
            sourceConnectorId: source.rawValue, externalId: externalId
        ) else { return false }
        if record.sources.count <= 1 {
            try await meetingRepository.delete(meetingIds: [record.event.id])
            emit(.deleted([record.event.id]))
            return true
        }
        let remaining = record.sources.filter {
            !($0.sourceConnectorId == source.rawValue && $0.externalId == externalId)
        }
        // Возврат РП (MEE-385, инв. 10 C-005, приёмка #105 п. 1): identity
        // (sourceConnectorId/externalId/icalUid) ПЕРЕСЧИТЫВАЕТСЯ ВСЕГДА шагом 1 (наибольший
        // lastModified среди оставшихся строк, тай-брейк — лексикографически меньший
        // sourceConnectorId), даже когда ушедший источник был identity. Содержимое (шаги
        // 2-3) пересчитывается ТЕМ ЖЕ правилом — шагами 1-6 целиком (`Self.merge`), если
        // хотя бы у одного из оставшихся источников есть снимок; если снимков не осталось
        // ни у кого — правило инв. 10 замораживает содержимое, `recomputingIdentity` трогает
        // только identity. Без пересчёта identity, если ушедший источник был identity,
        // `save` бросает constraintViolation: `sourcesIncludingOwnIdentity` (storage) не
        // находит identity `event` среди `remaining` и синтезировать её не вправе (инв. 31
        // C-010 v18 — синтез снимка собственной identity разрешён только при первом
        // сохранении с одним источником, не здесь).
        let recomputedEvent = try remaining.contains(where: { $0.payload != nil })
            ? Self.merge(sources: remaining, id: record.event.id)
            : Self.recomputingIdentity(of: record.event, remaining: remaining)
        try await meetingRepository.save(
            MeetingRecord(
                event: recomputedEvent, dedupKey: DedupKey.make(from: recomputedEvent),
                status: record.status, sources: remaining
            )
        )
        if recomputedEvent != record.event {
            emit(.upserted([recomputedEvent]))
        }
        return false
    }

    /// Шаг 1 правила слияния C-005 (наибольший `lastModified`, тай-брейк — лексикографически
    /// меньший `sourceConnectorId`) над IDENTITY-полями (`sourceConnectorId`/`externalId`/
    /// `icalUid`) оставшихся источников — инв. 10 C-005 требует пересчёта identity всегда,
    /// независимо от того, пересчитывается ли содержимое. `remaining` непусто по построению
    /// (вызывающая сторона уже отделила случай `count <= 1` до вызова).
    private static func recomputingIdentity(of event: MeetingEvent, remaining: [MeetingSource]) throws -> MeetingEvent {
        let winner = remaining.min { lhs, rhs in
            lhs.lastModified != rhs.lastModified
                ? lhs.lastModified > rhs.lastModified
                : lhs.sourceConnectorId < rhs.sourceConnectorId
        }!
        guard winner.sourceConnectorId != event.sourceConnectorId
            || winner.externalId != event.externalId
            || winner.icalUid != event.icalUid
        else {
            return event
        }
        return try MeetingEvent(
            id: event.id, sourceConnectorId: winner.sourceConnectorId, externalId: winner.externalId,
            icalUid: winner.icalUid, title: event.title, start: event.start, end: event.end,
            timeZone: event.timeZone, isAllDay: event.isAllDay, isCancelled: event.isCancelled,
            organizer: event.organizer, attendees: event.attendees, location: event.location,
            bodyText: event.bodyText, conference: event.conference, lastModified: event.lastModified
        )
    }
}
