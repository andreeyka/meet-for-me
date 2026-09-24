//  Инварианты C-001 §1, общие для MeetingEvent и MeetingEventPayload (C-006 §6.1).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ВЫНЕСЕНО СЮДА, А НЕ ОСТАВЛЕНО В `MeetingEvent`, ПОТОМУ ЧТО C-006 §6.1 ТРЕБУЕТ ЭТОГО
//  ДОСЛОВНО: «Список инвариантов 1, 2, 4, 6, 7 существует в domain-core в одном
//  экземпляре — внутренней функцией, которую вызывают validate() обоих типов, MeetingEvent
//  и MeetingEventPayload. Список, размноженный по двум типам, разойдётся на первой правке,
//  и расхождение не даст ошибки — оно даст два мнения о том, что валидно». Инвариант 3
//  держит сам `MeetingEvent.Person` (не дублируется здесь); инвариант 5 — сам
//  `MeetingEvent.Conference`; инвариант 6 не несёт ни строки кода — `title: String`
//  негодного значения `nil` не допускает по типу.
//
//  `id` ЗДЕСЬ НЕ ЧИТАЕТСЯ НИ РАЗУ: ни один из семи инвариантов C-001 §1 на него не
//  ссылается (C-006 §6.1, «вычитание пустое»), и потому общая функция принимает ровно те
//  поля, что есть у ОБОИХ типов — `MeetingEventPayload` без `id`, `MeetingEvent` с ним же,
//  просто не передаваемым сюда.

import Foundation

/// Поля общей функции одним значением: `function_parameter_count` SwiftLint (--strict,
/// «Core + Mac») не разрешает больше восьми параметров, а `owner` плюс восемь смысловых
/// полей были ими и шли отдельными параметрами.
struct MeetingEventFields {
    let start: Date
    let end: Date
    let lastModified: Date
    let timeZone: String
    let isAllDay: Bool
    let organizer: MeetingEvent.Person?
    let attendees: [MeetingEvent.Attendee]
    let conference: MeetingEvent.Conference?
}

/// Инварианты 1, 2, 4, 6, 7 плюс представимость (§0.2 п. 9) трёх полей `Date` — в одном
/// месте на оба типа C-001/C-006, которые их несут.
enum MeetingEventValidation {

    /// Ступени §0.2 п. 6 в порядке контракта: (а) вложенные значения → (в) представимость →
    /// (б) собственные инварианты. `owner` называет вызывающий тип (`contract`, `type`) —
    /// сама функция ни того, ни другого не выбирает.
    static func validate(owner: DomainOwner, fields: MeetingEventFields) throws {
        try fields.organizer?.validate()
        for attendee in fields.attendees {
            try attendee.validate()
        }
        try fields.conference?.validate()

        try owner.requireDate(fields.start, "start")
        try owner.requireDate(fields.end, "end")
        try owner.requireDate(fields.lastModified, "lastModified")

        try owner.check(fields.end >= fields.start, 1, "end", "end раньше start")
        try owner.check(TimeZone(identifier: fields.timeZone) != nil, 2, "timeZone",
                        "не идентификатор IANA: \(fields.timeZone)")
        try validateUniqueAddresses(owner, fields.attendees)
        try validateAllDayBounds(
            owner, start: fields.start, end: fields.end,
            isAllDay: fields.isAllDay, timeZone: fields.timeZone
        )
    }

    /// Инвариант 4: нарушителем является пара одинаковых адресов, а не элемент, — `path` есть
    /// имя коллекции (§0.1, правило 3). Элементы с `email == nil` не сравниваются друг с другом.
    private static func validateUniqueAddresses(
        _ owner: DomainOwner, _ attendees: [MeetingEvent.Attendee]
    ) throws {
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
    /// прочтение отвергло бы событие, которое построено по правилам этого же контракта.
    private static func validateAllDayBounds(
        _ owner: DomainOwner, start: Date, end: Date, isAllDay: Bool, timeZone: String
    ) throws {
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
