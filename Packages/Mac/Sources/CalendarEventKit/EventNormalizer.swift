//  EventNormalizer — нормализация сырых полей источника к инвариантам C-001 (IR-116).
//
//  Модуль: calendar-eventkit · Владелец: DEV-1 · Слой: плагин (адаптер системного API)
//
//  IR-116 (MEE-340) разрешён: нормализацию делает коннектор, независимо от транспорта
//  (C-006 v8 «Поведение»). Четыре вещи, к инвариантам C-001 их приводит эта сторона:
//  `email` (К10, К11), `timeZone` (К12), границы «весь день» (К13, К14), `conference` (К16,
//  развилка Р4 — своя эвристика, не входит в список «четырёх вещей» C-001).
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

    /// К12: идентификатор, не входящий в IANA-базу (гипотетический вход теста), заменяется на
    /// `"UTC"` — гарантирует `TimeZone(identifier:) != nil` у результата без отказа события
    /// целиком. Валидный идентификатор источника переносится без изменения.
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
        let end = calendar.date(byAdding: .day, value: 1, to: lastDayStart) ?? lastDayStart
        return (start, end)
    }

    /// К16, развилка Р4: эвристика по известным доменам конференц-провайдеров над `location`,
    /// заметками и URL-полем события — первое совпадение побеждает. Отдаёт только `https`-ссылки
    /// (инвариант 5 C-001 требует абсолютный `https` URL — не-`https` совпадение либо не
    /// найдено, либо отброшено этой же функцией, чтобы не уронить конструктор `Conference`
    /// вместо честного «эвристика не распознала»).
    static func detectConference(location: String?, notes: String?, url: URL?) -> (provider: String, joinUrl: URL)? {
        let rules: [(domain: String, provider: String)] = [
            ("zoom.us", "zoom"),
            ("meet.google.com", "meet"),
            ("teams.microsoft.com", "teams")
        ]
        var candidates: [URL] = []
        if let url { candidates.append(url) }
        for text in [location, notes].compactMap({ $0 }) {
            candidates.append(contentsOf: extractLinks(from: text))
        }
        for candidate in candidates {
            guard candidate.scheme?.lowercased() == "https", let host = candidate.host?.lowercased() else { continue }
            for rule in rules where host == rule.domain || host.hasSuffix("." + rule.domain) {
                return (rule.provider, candidate)
            }
        }
        return nil
    }

    private static func extractLinks(from text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }
}
