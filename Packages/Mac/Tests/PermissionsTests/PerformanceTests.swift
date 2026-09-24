//  К14, К18 (перечень MEE-74): половина «не позднее 500 мс» — измеряет реальное время без
//  единой инжектируемой задержки в проверяемом пути (MEE-379, аудит MEE-377, п.3). Шумит под
//  общей нагрузкой гейтящего раннера, а не поведение SUT — снята с гейтящего прогона тем же
//  приёмом, что `DomainCoreTests.PerformanceTests` (MEE-378): `XCTSkipUnless`, явный прогон
//  `RUN_PERFORMANCE_TESTS=1 swift test --package-path Packages/Mac --filter PerformanceTests`.
//  Собственно значения исходов (корректность) остаются в `RequestTests` — `test_c14_*`/`test_c18_*`.

import Foundation
import XCTest
@testable import Permissions

final class PerformanceTests: XCTestCase {

    func test_c14_c18_totalityCellsAnswerWithin500ms() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_PERFORMANCE_TESTS"] != nil,
            "измеряет реальное время — шумит под общей нагрузкой гейтящего раннера (MEE-379); " +
                "запуск явно: RUN_PERFORMANCE_TESTS=1"
        )
        for kind in RequestTests.withSystemStatus {
            for status in [PermissionStatus.notDetermined, .granted, .denied, .restricted, .unavailable, .unknown] {
                let harness = PermissionsHarness([kind: status])
                harness.statuses.answer(true, for: kind)
                let started = Date()
                _ = await harness.sut.request(kind)
                XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "\(kind) при \(status)")
            }
        }
        for status in [PermissionStatus.unknown, .granted, .denied] {
            let harness = PermissionsHarness()
            await harness.sut.note(observed: status, for: .systemAudioRecording)
            let started = Date()
            _ = await harness.sut.request(.systemAudioRecording)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "\(status)")
        }
        for sut in [SystemPermissions(), PermissionsHarness().sut] {
            let started = Date()
            _ = await sut.request(.systemAudioRecording)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        }
    }
}
