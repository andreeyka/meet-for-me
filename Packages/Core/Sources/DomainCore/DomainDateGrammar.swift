//  DomainDateGrammar — канонический вид `Date` и его грамматика чтения, C-001 §0.4.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Календарь здесь пролептический григорианский и считается арифметикой, а не Foundation.
//  Довод не стилистический: ICU-календарь `.gregorian` до 1582 года юлианский, и константа
//  нижней границы, собранная им, разошлась бы с грамматикой §0.4 ровно на двое суток —
//  на те самые двое, на которые `Date.distantPast` лежит ниже `0001-01-01T00:00:00.000Z`.
//  Границы диапазона §0.2 п. 9 и запись байтов выведены здесь из одного и того же счёта,
//  поэтому «переживает круг по равенству» верно по построению, а не по совпадению.

import Foundation

/// Канонический вид `YYYY-MM-DDThh:mm:ss.sssZ` и грамматика чтения
/// `YYYY-MM-DDThh:mm:ss[.f{1,9}](Z|±hh:mm)`.
enum DomainDateGrammar {

    static let minMilliseconds = daysFromCivil(year: 1, month: 1, day: 1) * 86_400_000
    static let maxMilliseconds = daysFromCivil(year: 9999, month: 12, day: 31) * 86_400_000 + 86_399_999

    static let minSeconds = Double(minMilliseconds) / 1000
    static let maxSeconds = Double(maxMilliseconds) / 1000

    /// Нижняя граница диапазона §0.2 п. 9 — `0001-01-01T00:00:00.000Z`.
    static let lowerBound = Date(timeIntervalSince1970: minSeconds)
    /// Верхняя граница диапазона §0.2 п. 9 — `9999-12-31T23:59:59.999Z`.
    static let upperBound = Date(timeIntervalSince1970: maxSeconds)

    static func isInRange(_ date: Date) -> Bool {
        let seconds = date.timeIntervalSince1970
        return seconds.isFinite && seconds >= minSeconds && seconds <= maxSeconds
    }

    // MARK: - Запись

    /// Канонический вид или `nil`, если значение вне представимого диапазона.
    static func string(from date: Date) -> String? {
        let scaled = (date.timeIntervalSince1970 * 1000).rounded(.toNearestOrAwayFromZero)
        guard scaled.isFinite, scaled >= Double(minMilliseconds), scaled <= Double(maxMilliseconds) else {
            return nil
        }
        let total = Int(scaled)
        let days = floorDiv(total, 86_400_000)
        let inDay = total - days * 86_400_000
        let civil = civilFromDays(days)
        let head = pad(civil.year, 4) + "-" + pad(civil.month, 2) + "-" + pad(civil.day, 2)
        let time = pad(inDay / 3_600_000, 2) + ":" + pad((inDay / 60_000) % 60, 2)
            + ":" + pad((inDay / 1_000) % 60, 2) + "." + pad(inDay % 1_000, 3)
        return head + "T" + time + "Z"
    }

    // MARK: - Чтение

    /// Значение по грамматике §0.4 или `nil`, если форма или диапазон нарушены.
    static func date(from text: String) -> Date? {
        var cursor = Cursor(bytes: Array(text.utf8))
        guard let stamp = cursor.readStamp(), cursor.isAtEnd else { return nil }
        guard isCalendarValid(stamp) else { return nil }
        var total = daysFromCivil(year: stamp.year, month: stamp.month, day: stamp.day) * 86_400_000
        total += stamp.hour * 3_600_000 + stamp.minute * 60_000 + stamp.second * 1_000
        total += stamp.milli - stamp.offsetMinutes * 60_000
        guard total >= minMilliseconds, total <= maxMilliseconds else { return nil }
        return Date(timeIntervalSince1970: Double(total) / 1000)
    }

    private static func isCalendarValid(_ stamp: Stamp) -> Bool {
        guard stamp.month >= 1, stamp.month <= 12 else { return false }
        guard stamp.day >= 1, stamp.day <= daysInMonth(year: stamp.year, month: stamp.month) else { return false }
        return stamp.hour <= 23 && stamp.minute <= 59 && stamp.second <= 59
    }

    // MARK: - Календарная арифметика

    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let shifted = year - (month <= 2 ? 1 : 0)
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let monthPrime = month + (month > 2 ? -3 : 9)
        let dayOfYear = (153 * monthPrime + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        default: return isLeapYear(year) ? 29 : 28
        }
    }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    private static func floorDiv(_ lhs: Int, _ rhs: Int) -> Int {
        let quotient = lhs / rhs
        let hasRemainder = lhs % rhs != 0
        return hasRemainder && ((lhs < 0) != (rhs < 0)) ? quotient - 1 : quotient
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        var text = String(value)
        while text.count < width {
            text = "0" + text
        }
        return text
    }
}

/// Разобранные поля отметки времени: календарные значения ещё не проверены.
private struct Stamp {
    let year: Int
    let month: Int
    let day: Int
    let hour: Int
    let minute: Int
    let second: Int
    let milli: Int
    let offsetMinutes: Int
}

/// Побайтовый курсор по строке отметки времени.
private struct Cursor {
    let bytes: [UInt8]
    var index = 0

    var isAtEnd: Bool { index == bytes.count }

    var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    mutating func readStamp() -> Stamp? {
        guard let year = digits(4), match(0x2D), let month = digits(2), match(0x2D) else { return nil }
        guard let day = digits(2), match(0x54) else { return nil }
        guard let hour = digits(2), match(0x3A), let minute = digits(2), match(0x3A) else { return nil }
        guard let second = digits(2) else { return nil }
        var milli = 0
        if match(0x2E) {
            guard let fraction = fractionMilliseconds() else { return nil }
            milli = fraction
        }
        guard let offset = zoneOffsetMinutes() else { return nil }
        return Stamp(year: year, month: month, day: day, hour: hour,
                     minute: minute, second: second, milli: milli, offsetMinutes: offset)
    }

    mutating func digits(_ count: Int) -> Int? {
        guard index + count <= bytes.count else { return nil }
        var value = 0
        for offset in 0..<count {
            let byte = bytes[index + offset]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            value = value * 10 + Int(byte - 0x30)
        }
        index += count
        return value
    }

    mutating func match(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }

    /// От одного до девяти дробных разрядов, округлённых до миллисекунды правилом
    /// `.toNearestOrAwayFromZero`; результат `1000` законен и переносится в секунды.
    mutating func fractionMilliseconds() -> Int? {
        var value = 0
        var taken = 0
        while taken < 9, let byte = current, byte >= 0x30, byte <= 0x39 {
            value = value * 10 + Int(byte - 0x30)
            index += 1
            taken += 1
        }
        guard taken >= 1 else { return nil }
        if let byte = current, byte >= 0x30, byte <= 0x39 { return nil }
        var nanoseconds = value
        var missing = 9 - taken
        while missing > 0 {
            nanoseconds *= 10
            missing -= 1
        }
        return (nanoseconds + 500_000) / 1_000_000
    }

    mutating func zoneOffsetMinutes() -> Int? {
        if match(0x5A) { return 0 }
        let sign: Int
        if match(0x2B) {
            sign = 1
        } else if match(0x2D) {
            sign = -1
        } else {
            return nil
        }
        guard let hours = digits(2), match(0x3A), let minutes = digits(2) else { return nil }
        guard hours <= 23, minutes <= 59 else { return nil }
        return sign * (hours * 60 + minutes)
    }
}
