//  EventKitCoreGateway — реализация шва поверх системного `EKEventStore`.
//
//  Модуль: calendar-eventkit · Владелец: DEV-1 · Слой: плагин (адаптер системного API)
//
//  Не несёт авторизации: ни право `.calendars`, ни `requestFullAccessToEvents()` здесь не
//  трогаются — вызывающая сторона (`EventKitConnector`) уже убедилась в праве через
//  `PermissionsPort` до любого обращения сюда (MEE-339, раздел «Шов»).
//
// СТРОКА: развилка Р7 (различение «похоже на потерю права» / «иная причина», MEE-339) —
//  калибровка без М2 (живой Mac) не выполнена. `EKEventStore.calendars(for:)` и
//  `.events(matching:)` — НЕ throwing-методы в документированном API EventKit (в отличие от
//  операций записи/новых async-методов авторизации, которых этот шов сознательно не вызывает);
//  практически это означает, что при отозванном праве метод современного EventKit, по всей
//  видимости, тихо отдаёт пустой результат, а не бросает, — но это не измерено ни разу на живой
//  машине (план MEE-343 §4 п. 6: «без него классификация остаётся эвристикой без проверенного
//  основания»). Оба случая `EventKitGatewayError` объявлены и проверены на уровне коннектора
//  (К24) через `FakeEventKitGateway`, но эта, реальная реализация ниже сегодня НЕ ИМЕЕТ ни
//  одного пути, производящего ни один из двух случаев, — раз исходные вызовы не бросают. Не
//  решаю сама: владелец — DEV-1 (я же), условие снятия — М2 (перечень MEE-339, план MEE-343 §5),
//  срок — до приёмки маршрута К24 в реальных условиях.

import EventKit
import Foundation

final class EventKitCoreGateway: EventKitGateway, @unchecked Sendable {

    private let store = EKEventStore()

    func calendars() async throws -> [RawCalendar] {
        store.calendars(for: .event).map {
            RawCalendar(calendarId: $0.calendarIdentifier, title: $0.title, isReadOnly: !$0.allowsContentModifications)
        }
    }

    func events(from: Date, to: Date, calendarIds: [String]) async throws -> [RawEvent] {
        let selected = store.calendars(for: .event).filter { calendarIds.contains($0.calendarIdentifier) }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: selected)
        return store.events(matching: predicate).map(Self.rawEvent)
    }

    private static func rawEvent(from event: EKEvent) -> RawEvent {
        RawEvent(
            calendarId: event.calendar.calendarIdentifier,
            externalId: event.eventIdentifier,
            // Приватный API не даёт публичного доступа к iCalUID отдельно от eventIdentifier —
            // поле контракта опционально, ни один критерий MEE-339 его не проверяет.
            icalUid: nil,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            timeZoneIdentifier: event.timeZone?.identifier ?? TimeZone.current.identifier,
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            organizer: event.organizer.map(rawPerson),
            attendees: (event.attendees ?? []).map(rawAttendee),
            location: event.location,
            notes: event.notes,
            url: event.url,
            lastModified: event.lastModifiedDate ?? event.startDate
        )
    }

    private static func rawPerson(from participant: EKParticipant) -> RawPerson {
        // EventKit не даёт отдельного поля email — адрес несёт `url` схемой `mailto:`
        // (нормализация, включая снятие этой схемы, — обязанность коннектора, не шва, IR-116).
        RawPerson(name: participant.name, email: participant.url.absoluteString)
    }

    private static func rawAttendee(from participant: EKParticipant) -> RawAttendee {
        RawAttendee(
            person: rawPerson(from: participant),
            responseStatus: mapStatus(participant.participantStatus),
            // EventKit не даёт публичного признака «участник опционален» на EKParticipant.
            isOptional: false
        )
    }

    private static func mapStatus(_ status: EKParticipantStatus) -> RawResponseStatus {
        switch status {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .pending: return .needsAction
        case .unknown, .delegated, .completed, .inProcess: return .unknown
        @unknown default: return .unknown
        }
    }
}
