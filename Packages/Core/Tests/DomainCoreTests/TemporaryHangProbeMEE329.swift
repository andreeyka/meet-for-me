//  ВРЕМЕННЫЙ файл — только для проверки MEE-329 (timeout-minutes в ci.yml)
//  на отдельной ветке. Не должен попасть в main: снимается сразу после того,
//  как прогон CI на этой ветке подтвердит красный таймаут в названный срок.

import XCTest

final class TemporaryHangProbeMEE329: XCTestCase {
    func testHangsForeverOnPurpose() async throws {
        try await Task.sleep(nanoseconds: .max)
    }
}
