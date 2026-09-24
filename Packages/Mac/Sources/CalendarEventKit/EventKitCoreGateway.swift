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
            externalId: externalId(for: event),
            // Возврат РП (Д9, 24.09) — самокоррекция: `calendarItemExternalIdentifier` ЕСТЬ
            // публичный API (не приватный, как утверждал прежний комментарий) — стабильный
            // межустройственный UID, в отличие от `eventIdentifier` (локален хранилищу).
            icalUid: event.calendarItemExternalIdentifier,
            title: event.title ?? "",
            start: event.startDate,
            end: event.endDate,
            timeZoneIdentifier: event.timeZone?.identifier ?? Self.floatingEventTimeZoneIdentifier,
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            organizer: event.organizer.map(rawPerson),
            attendees: (event.attendees ?? []).map(rawAttendee),
            location: event.location,
            notes: event.notes,
            url: event.url,
            lastModified: event.lastModifiedDate ?? Self.lastModifiedFallback(for: event)
        )
    }

    // Возврат РП (Д1, блокирует, 24.09): `event.eventIdentifier` ОДИН И ТОТ ЖЕ у всех вхождений
    // повторяющегося события — К19 (развёрнутые вхождения, каждое со своим `externalId`) на
    // живом пути был бы нарушен этим полем в одиночку, и `calendar-hub` склеил бы вхождения
    // при дедупе по этому же полю. `occurrenceDate` — дата ИМЕННО этого вхождения, у каждого
    // из N вхождений одного `eventIdentifier` — своя.
    //
    // СТРОКА: форма составного идентификатора не названа ни контрактом, ни перечнем — решение
    // здесь, не цитата. Беру `"<eventIdentifier>:<occurrenceDate как Unix-время в секундах>"`.
    // Вилка не решена мной до конца:
    // (а) эта форма стабильна между запусками (не зависит от порядка перечисления,
    //     только от значений двух полей EventKit) и не пересекается с одиночными
    //     (неповторяющимися) событиями, у которых `occurrenceDate == startDate` — коллизия с
    //     другим событием потребовала бы совпадения обоих полей одновременно;
    // (б) секундная точность `occurrenceDate` теоретически схлопнула бы два РАЗНЫХ вхождения
    //     одного правила повторения, начинающихся в одну и ту же секунду, — сценарий, которого
    //     ни один существующий тест не проверяет и которого сама семантика правил повторения
    //     EventKit (шаг не короче минуты) не производит на практике.
    // М1 п. 5 (план MEE-343 §5) — единственный источник, калибрующий факт про K19 на живом
    // EventKit; эта строка калибрует только ФОРМУ идентификатора, не сам факт различимости.
    private static func externalId(for event: EKEvent) -> String {
        "\(event.eventIdentifier ?? ""):\(Int(event.occurrenceDate.timeIntervalSince1970))"
    }

    // СТРОКА: «плавающее» событие (`event.timeZone == nil` — EventKit это допускает: время
    // читается как есть в любом поясе просмотра, без собственной привязки) не описано ни
    // контрактом C-006/C-001, ни перечнем MEE-339 — решение здесь, не цитата. Беру часовой пояс
    // ПРОЦЕССА (`TimeZone.current`) на момент чтения. Вилка не решена мной:
    // (а) это разумное приближение — большинство «плавающих» событий (дни рождения, годовщины)
    //     осмысленны в поясе наблюдателя, и без него `timeZoneIdentifier` контракта (C-001,
    //     инвариант 2 — валидный IANA-идентификатор) вообще нечем было бы заполнить;
    // (б) `TimeZone.current` — пояс МАШИНЫ DEV-1/пользователя в момент синхронизации, не
    //     обязательно пояс, в котором событие «имелось в виду» создателем; правильный ответ
    //     контракт не называет вовсе.
    private static var floatingEventTimeZoneIdentifier: String { TimeZone.current.identifier }

    // СТРОКА: `lastModifiedDate == nil` (EventKit допускает — поле опционально) не описано ни
    // контрактом, ни перечнем. Беру `startDate` события как нижнюю оценку возраста. Вилка не
    // решена мной: (а) `startDate` — единственное другое поле-`Date`, гарантированно связанное
    // с этим же событием, и не может быть МЕНЬШЕ реальной даты последнего изменения (событие не
    // могло измениться раньше, чем оно начинается, по построению большинства сценариев создания);
    // (б) для события, отредактированного давно после своего `startDate` в прошлом, эта оценка
    // занижает реальный возраст изменения произвольно сильно — контракт не даёт лучшего сигнала
    // на этот случай, и точная семантика «когда именно EventKit оставляет `lastModifiedDate`
    // пустым» не измерена ни разу.
    private static func lastModifiedFallback(for event: EKEvent) -> Date { event.startDate }

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
