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

    /// Возврат MEE-317 (24.09, затем второй круг): прежняя версия сверяла `scaleErrorMs` события
    /// с `ScaleError.compute` от ЕГО ЖЕ `fileMinusHostMs` — тавтология: порт, который считает
    /// `fileMinusHostMs` неверно (или не считает вовсе, отдавая 0) и получает от чистой функции
    /// то же самое неверное число, эту проверку тоже пройдёт. Здесь `fileMinusHostMs` — известное
    /// заранее значение, посчитанное тестом из входов, заданных через шов (`hostOrigin` — hostTime
    /// первого буфера, `atMs` — позиция трека к моменту разрыва, `atHostTime` разрыва), а не
    /// прочитанное из проверяемого события.
    ///
    /// Числа: первый буфер mic — 480 кадров на 48 кГц → 10 мс позиции трека, hostTime 1000 —
    /// `hostOrigin`. `tapInvalidated` в `atHostTime: 5000` → `hostPositionMs = 5000 − 1000 = 4000`,
    /// `fileMinusHostMs = 10 − 4000 = −3990` → `scaleErrorMs = ceil(3990) = 3990` (выше floor 150 —
    /// число, которое ошибочная реализация с захардкоженным 0/floor не воспроизвела бы).
    func test_k10_scaleErrorMsOnRealDiscontinuityMatchesValueSetThroughTheSeam() async throws {
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

        let expectedFileMinusHostMs = -3_990
        let expectedScaleErrorMs = ScaleError.compute(
            reason: .sourceGone, fileMinusHostMs: Double(expectedFileMinusHostMs)
        )
        let actualFileMinusHostMs = try XCTUnwrap(discontinuity.fileMinusHostMs)
        XCTAssertEqual(actualFileMinusHostMs, expectedFileMinusHostMs,
                       "измерение недостачи файла — по числам, заданным через шов, не по памяти реализации")
        XCTAssertEqual(discontinuity.scaleErrorMs, expectedScaleErrorMs,
                       "scaleErrorMs — от значения, известного заранее, а не от прочитанного из того же события")
        XCTAssertNotEqual(discontinuity.scaleErrorMs, 150,
                          "реализация, потерявшая измерение и всегда отдающая floor, здесь не прошла бы")
    }
}
