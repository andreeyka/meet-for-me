//  MEE-320: `DomainTestKit.ManualClock` — C-013 §«Фейк для тестов» требует его прямо: К84
//  (часть). «`ManualClock` двигает время по команде теста.»

import XCTest
import DomainTestKit

final class ManualClockTests: XCTestCase {

    func test_mee320_manualClock_startsAtGivenMoment() {
        let epoch = Date(timeIntervalSince1970: 500)
        let clock = ManualClock(now: epoch)
        XCTAssertEqual(clock.now(), epoch)
    }

    func test_mee320_manualClock_defaultsToUnixEpoch() {
        let clock = ManualClock()
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 0), "детерминированное умолчание")
    }

    func test_mee320_manualClock_advanceMovesForwardAndBackward() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 1_000))
        clock.advance(by: 30)
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 1_030))
        clock.advance(by: -10)
        XCTAssertEqual(clock.now(), Date(timeIntervalSince1970: 1_020), "отрицательный интервал двигает назад")
    }

    func test_mee320_manualClock_setJumpsToGivenMoment() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 0))
        let target = Date(timeIntervalSince1970: 999_999)
        clock.set(target)
        XCTAssertEqual(clock.now(), target)
    }

    /// Контракт требует именно значение типа `@Sendable () -> Date` — замыкание,
    /// подставляемое туда, где очередь ожидает такой параметр. Обёрнуто явно
    /// (`{ clock.now() }`), а не взято ссылкой на метод (`clock.now`): последняя форма даёт
    /// в CI предупреждение о безопасности гонки данных при неявном преобразовании
    /// связанного метода к `@Sendable`-типу (возврат по приёмке MEE-320), хотя ссылка и
    /// остаётся типом `() -> Date`, легальным для преобразования, — явное замыкание снимает
    /// предупреждение и не меняет поведение ни на одном входе.
    func test_mee320_manualClock_methodReferenceMatchesClosureContract() {
        let clock = ManualClock(now: Date(timeIntervalSince1970: 42))
        let closure: @Sendable () -> Date = { clock.now() }
        XCTAssertEqual(closure(), Date(timeIntervalSince1970: 42))

        clock.advance(by: 8)
        XCTAssertEqual(closure(), Date(timeIntervalSince1970: 50), "замыкание видит текущее, а не снятое значение")
    }
}
