//  К10 — scaleErrorMs по правилу §«Оценка ошибки шкалы» (план MEE-315). Единственная зависимость
//  формулы — `reason` и `fileMinusHostMs`, поэтому критерий проверяется прямым вызовом
//  `ScaleError.compute`, без сеанса и без шва (способ А по духу плана: реальный код, не фейк
//  результата).

import DomainCore
import XCTest
@testable import Capture

final class ScaleErrorTests: XCTestCase {

    func test_k10_rebuildSleepSourceGoneWithoutMeasurement_useFloor150() {
        for reason: RecordingManifest.DiscontinuityReason in [.rebuild, .sleep, .sourceGone] {
            XCTAssertEqual(ScaleError.compute(reason: reason, fileMinusHostMs: nil), 150, "\(reason)")
        }
    }

    func test_k10_rebuildSleepSourceGoneWithMeasurementAbove150_useCeilOfMeasurement() {
        for reason: RecordingManifest.DiscontinuityReason in [.rebuild, .sleep, .sourceGone] {
            XCTAssertEqual(ScaleError.compute(reason: reason, fileMinusHostMs: 203.2), 204, "\(reason)")
            XCTAssertEqual(ScaleError.compute(reason: reason, fileMinusHostMs: -203.2), 204, "\(reason) (по модулю)")
        }
    }

    func test_k10_rebuildSleepSourceGoneWithMeasurementBelowFloor_stillUsesFloor() {
        // «Ниже floor значение не пишется никогда, даже если измерение дало меньше» (контракт, дословно).
        XCTAssertEqual(ScaleError.compute(reason: .rebuild, fileMinusHostMs: 12), 150)
    }

    func test_k10_droppedWithoutMeasurement_isZero() {
        XCTAssertEqual(ScaleError.compute(reason: .dropped, fileMinusHostMs: nil), 0)
    }

    func test_k10_droppedWithMeasurement_usesCeilOfMeasurement() {
        XCTAssertEqual(ScaleError.compute(reason: .dropped, fileMinusHostMs: 7.1), 8)
    }

    func test_k10_truncatedIsAlwaysZero() {
        XCTAssertEqual(ScaleError.compute(reason: .truncated, fileMinusHostMs: nil), 0)
        XCTAssertEqual(ScaleError.compute(reason: .truncated, fileMinusHostMs: 999), 999)
    }
}
