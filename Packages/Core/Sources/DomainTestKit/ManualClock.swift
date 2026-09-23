//  ManualClock — управляемый тестом источник времени очереди. C-013 §«Фейк для тестов»
//  требует его прямо: «время очереди подаётся замыканием `@Sendable () -> Date` и
//  параметром `now:`; `ManualClock` — управляемый тестом источник этого замыкания».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  НЕ ТО ЖЕ САМОЕ, ЧТО НУЖНО БЫЛО C-018: там `Scheduler` берёт `now: Date` ОДНИМ параметром
//  на вызов (MEE-311 §7, довод QA), и `ManualClock` для этого не заводился. Здесь время
//  требуется ДВИГАТЬ МЕЖДУ ВЫЗОВАМИ ТЕСТА — К59, К61, К62 плана проверяют лизинг и
//  экспоненциальный откат, которые наблюдаются только на последовательности показаний
//  часов, а не на одном фиксированном моменте.
//
//  `now` — МЕТОД, а не свойство: значение, отданное `@Sendable () -> Date`, обязано
//  сниматься в момент вызова, а свойство читается тем же синтаксисом, что и метод без
//  аргументов, — разница в семантике незаметна на месте вызова и заметна только здесь,
//  в контракте. Ссылка на метод (`clock.now`) сама по себе значение типа
//  `@Sendable () -> Date`, которое и требует контракт.

import Foundation

/// Источник времени, который тест двигает явно. Замыкание `clock.now` подставляется туда,
/// где очередь ожидает `@Sendable () -> Date`.
public final class ManualClock: @unchecked Sendable {

    private let lock = NSLock()
    private var current: Date

    public init(now: Date = Date(timeIntervalSince1970: 0)) {
        current = now
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Текущее показание часов. Тип и место вызова — то, что контракт называет
    /// `@Sendable () -> Date`.
    public func now() -> Date {
        locked { current }
    }

    /// Сдвинуть часы вперёд (отрицательное значение — назад) на заданный интервал.
    public func advance(by seconds: TimeInterval) {
        locked { current = current.addingTimeInterval(seconds) }
    }

    /// Поставить часы на заданный момент безотносительно текущего.
    public func set(_ date: Date) {
        locked { current = date }
    }
}
