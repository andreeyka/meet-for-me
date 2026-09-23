//  ДИАГНОСТИКА (временный файл, снимается следующим коммитом): возврат части 1, п. 11 — доказать
//  одним искусственно зависшим тестом в отдельном прогоне, что `executionTimeAllowance = 10`
//  (`CaptureAsyncTestCase`) действительно ловит зависание `swift test`, а не проходит незаметно.

import XCTest
@testable import Capture

final class ZZDiagnosticHangTest: CaptureAsyncTestCase {
    func test_deliberateHangCaughtByExecutionTimeAllowance() async throws {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}
