//  EventNormalizer — нормализация сырых полей источника к инвариантам C-001 (IR-116).
//
//  Модуль: calendar-eventkit · Владелец: DEV-1 · Слой: плагин (адаптер системного API)
//
//  IR-116 (MEE-340) разрешён: нормализацию делает коннектор, независимо от транспорта
//  (C-006 v8 «Поведение»). Три из четырёх вещей, к инвариантам C-001 их приводит эта сторона,
//  живут здесь: `email` (К10, К11), `timeZone` (К12), границы «весь день» (К13, К14).
//  `conference` (К29) — не здесь: C-009 v11 (IR-118) отдаёт разбор ссылки `PlatformResolver`,
//  см. `EventKitConnector.resolveConference`.
//
//  Представимость трёх полей `Date` (К17, C-001 §0.2 п. 9) здесь НЕ проверяется отдельно —
//  `MeetingEventPayload.init` сам зовёт `validate()`, а тот — `requireDate` на каждом из трёх;
//  эта сторона передаёт значения как есть, инвариант 0 ловит выход за диапазон сам.

import Foundation

enum EventNormalizer {

    /// К10/К11: нижний регистр, без префикса `mailto:` (EventKit отдаёт адрес участника через
    /// `EKParticipant.url`, схема `mailto:`); синтаксически негодный адрес — `nil`, не потеря
    /// всего события (C-001 v13 «Поведение», дословно: «терять из-за него всё событие нельзя»).
    static func normalizedEmail(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if email.hasPrefix("mailto:") {
            email.removeFirst("mailto:".count)
        }
        return isSyntacticallyValid(email) ? email : nil
    }

    /// Та же форма, что `MeetingEvent.Person.isNormalized` проверяет по факту (инвариант 3):
    /// ровно один `@`, обе части непустые, нет пробельных/управляющих символов. Не переиспользует
    /// эту функцию напрямую — она `internal` в `domain-core`, за границей модуля недостижима;
    /// список условий сверен с её кодом дословно, не изобретён заново.
    private static func isSyntacticallyValid(_ email: String) -> Bool {
        guard !email.isEmpty else { return false }
        guard !email.unicodeScalars.contains(where: { $0.value <= 0x20 }) else { return false }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        return !parts[0].isEmpty && !parts[1].isEmpty
    }

    // СТРОКА: возврат РП (Д8, 24.09) — какое именно значение подставлять вместо не-IANA
    // идентификатора (К12), не называет ни контракт, ни перечень: только требование
    // `TimeZone(identifier:) != nil` у результата (само по себе допускает любой валидный
    // идентификатор). Беру `"UTC"`. Вилка не решена мной:
    // (а) `"UTC"` — нейтральный, не искажающий часы события в какую-либо конкретную сторону
    //     (в отличие, например, от `TimeZone.current` — пояса машины, произвольно смещённого
    //     от реального намерения источника события);
    // (б) `"UTC"` всё равно ИСКАЖАЕТ отображаемое локальное время события — контракт не
    //     говорит, что искажение допустимо вовсе, только что оно не должно приводить к отказу
    //     конструктора; на практике вход недостижим живым EventKit (К12, гипотетический вход).
    static func ianaTimeZoneIdentifier(_ raw: String) -> String {
        TimeZone(identifier: raw) != nil ? raw : "UTC"
    }

    /// К13/К14: границы «весь день» — первое мгновение своих суток (`start`) и первое мгновение
    /// СЛЕДУЮЩИХ суток (`end`), через `Calendar.startOfDay(for:)`, не через компоненты — в сутки
    /// перехода летнего/зимнего времени локальной полуночи может не существовать вовсе (К14,
    /// фикстура `Asia/Beirut`), и компонентное прочтение отвергло бы валидное значение.
    static func allDayBounds(rawStart: Date, rawEnd: Date, timeZoneIdentifier: String) -> (start: Date, end: Date) {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else {
            // Недостижимо на практике: вызывающая сторона всегда передаёт сюда уже нормализованный
            // идентификатор (`ianaTimeZoneIdentifier` выше) — запасной путь только для честности типа.
            return (rawStart, rawEnd)
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: rawStart)
        let lastDayStart = calendar.startOfDay(for: rawEnd)
        // НЕ `calendar.date(byAdding: .day, value: 1, to: lastDayStart)`: в сутки, где
        // локальной полуночи не существует (К14, Beirut), `lastDayStart` сам читается по
        // местным часам как 01:00, не 00:00 — сложение «+1 сутки» стремится сохранить ЭТО
        // же часовое чтение на следующих сутках, а не их настоящую полночь, и «конец» съезжает
        // на час. Вместо этого — сдвиг заведомо ВНУТРЬ следующих суток (36 часов хватает при
        // любом реальном сдвиге DST) и `startOfDay` уже ОТ него: так результат — канонический
        // старт следующих суток по часам Calendar, не унаследованное от `lastDayStart` чтение.
        let wellInsideNextDay = lastDayStart.addingTimeInterval(36 * 3600)
        let end = calendar.startOfDay(for: wellInsideNextDay)
        return (start, end)
    }

    // Развилка Р4 (собственная эвристика по трём доменам) снята: C-009 v11 закрыла IR-118 —
    // разбор ссылки на созвон делает `PlatformResolver.resolve(text:source:)`, инжектированный
    // составным корнем `app-ui` (см. `EventKitConnector.resolveConference`), не эта функция.
}
