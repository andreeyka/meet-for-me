//  ВРЕМЕННЫЙ файл — только для проверки MEE-329 (timeout-minutes в ci.yml)
//  на отдельной ветке. Не должен попасть в main: снимается сразу после того,
//  как прогон CI на этой ветке подтвердит красный таймаут в названный срок.

import XCTest

final class TemporaryHangProbeMEE329: XCTestCase {
    func testHangsForeverOnPurpose() async throws {
        // `Task.sleep(nanoseconds: .max)` не годится: первый прогон (run
        // 35928253699) прошёл этим же файлом за 0.0 с — по всей видимости,
        // переполнение при вычислении дедлайна из UInt64.max. Цикл с
        // маленьким сном на каждом шаге такого переполнения не даёт и
        // виснет буквально, а не по недосмотру арифметики.
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
