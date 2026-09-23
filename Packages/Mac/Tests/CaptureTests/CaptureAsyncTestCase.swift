//  CaptureAsyncTestCase — общий предел времени на тест: повисший async-тест не должен вешать
//  весь прогон CI без вердикта (найдено на себе — MEE-317, часть 1: забытый resolveMicrophone
//  в одном тесте подвесил гонку с ManualDeadline навсегда, а с ней весь `swift test`).
//
//  `executionTimeAllowance` — штатный механизм XCTest для async-тестов: по истечении предела
//  тест проваливается таймаутом, а не висит до предела самой работы CI. Величина — 10 секунд:
//  с большим запасом против реальной суммы `Task.sleep` в самом длинном тесте (сотни мс).

import XCTest

class CaptureAsyncTestCase: XCTestCase {
    override var executionTimeAllowance: TimeInterval { 10 }
}
