//  К10 — scaleErrorMs по правилу §«Оценка ошибки шкалы» (план MEE-315). Единственная зависимость
//  формулы — `reason` и `fileMinusHostMs`, поэтому критерий проверяется прямым вызовом
//  `ScaleError.compute`, без сеанса и без шва (способ А по духу плана: реальный код, не фейк
//  результата).

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class ScaleErrorTests: CaptureAsyncTestCase {

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
        // Возврат MEE-317 (24.09): «безусловно» в прежнем комментарии выдавало собственную
        // формулировку за дословную цитату контракта — контракт этого слова не содержит.
        // Утверждение по существу верное (измерение для `.truncated` не подставляется, даже если
        // вызывающая сторона его передаст) остаётся, но без ложной пометки «дословно».
        XCTAssertEqual(ScaleError.compute(reason: .truncated, fileMinusHostMs: 999), 0)
    }

    // MARK: - К10 (продолжение). Значение из реального разрыва порта, не только чистой функции

    /// Возврат MEE-317 (24.09): прежние тесты звали `ScaleError.compute` напрямую — этого
    /// достаточно и для реализации, где `AudioCaptureImplRebuild` считает `fileMinusHostMs`
    /// неправильно или не передаёт его в `ScaleError.compute` вовсе (например, забытый аргумент,
    /// свой захардкоженный 0). Здесь — настоящий сеанс, настоящая пересборка, и сравнение
    /// `scaleErrorMs` события с тем, что даёт чистая функция от ЕЁ ЖЕ `fileMinusHostMs` — те же
    /// два поля одного события должны быть внутренне согласованы через реальный путь порта.
    func test_k10_scaleErrorMsOnRealDiscontinuityMatchesComputeOfItsOwnMeasurement() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()

        let collector = Task { () -> CaptureDiscontinuity? in
            for await event in harness.port.events() {
                if case .discontinuity(let discontinuity) = event { return discontinuity }
            }
            return nil
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        try await harness.start(directory: directory)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        try await Task.sleep(nanoseconds: 20_000_000)

        harness.gateway.emit(.tapInvalidated(atHostTime: 5_000))
        try await Task.sleep(nanoseconds: 20_000_000)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 5_050))

        let received = await collector.value
        let discontinuity = try XCTUnwrap(received)
        XCTAssertEqual(discontinuity.reason, .sourceGone)
        let expected = ScaleError.compute(
            reason: discontinuity.reason, fileMinusHostMs: discontinuity.fileMinusHostMs.map(Double.init)
        )
        XCTAssertEqual(discontinuity.scaleErrorMs, expected,
                       "scaleErrorMs реального разрыва — та же формула от его же измерения, не отдельное число")
    }
}
