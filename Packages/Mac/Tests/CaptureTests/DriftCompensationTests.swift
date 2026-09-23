//  К6 — компенсация дрейфа включена на каждой сборке aggregate device безусловно (инвариант 6).
//  План MEE-315. Возврат MEE-317 (24.09): шов обязан отдавать этот аргумент отдельным журналом,
//  а не только сам факт вызова `buildAggregate` — тест утверждает «true» на каждом из них,
//  а не «вызов случился».

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class DriftCompensationTests: CaptureAsyncTestCase {

    func test_k06_driftCompensationTrueOnEveryBuildAggregateCall() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        // Десять пересборок подряд (инвалидация tap — тот же tap, новая сборка aggregate,
        // инвариант 4) — «в каждом из десяти» дословно возврата РП. Буфер после каждой
        // инвалидации разрешает `pendingRebuild` (`resolveRebuild`), иначе следующая
        // инвалидация была бы отброшена — `beginRebuild` не начинает вторую пересборку поверх
        // ещё не разрешённой первой. `hostTime` строго возрастает по всему сценарию (как в
        // продакшене — монотонные часы): `beginRebuild` считает `atHostTime - session.hostOrigin`
        // без перевода в знаковый тип (в отличие от `resolveRebuild`), и невозрастающее значение
        // здесь — не сценарий продакшена, а ловушка беззнакового вычитания в самом тесте.
        for index in 0..<10 {
            let invalidatedAt = UInt64(1_000 + index * 100)
            harness.gateway.emit(.tapInvalidated(atHostTime: invalidatedAt))
            try await Task.sleep(nanoseconds: 5_000_000)
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: invalidatedAt + 50))
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        _ = try await harness.port.stop()

        XCTAssertEqual(harness.gateway.aggregateBuildCount, 11, "старт + десять пересборок")
        XCTAssertTrue(harness.gateway.aggregateBuildArgs.allSatisfy(\.driftCompensation),
                      "компенсация дрейфа — true на каждом вызове buildAggregate без исключений")
    }

    /// Возврат MEE-317 (третий круг): «между сеансами» — второй `start()` после `stop()`
    /// первого, не только повторные пересборки внутри одного сеанса.
    func test_k06_driftCompensationTrueAcrossTwoConsecutiveSessions() async throws {
        let harness = Harness()

        let firstDirectory = try Harness.makeDirectory()
        try await harness.start(directory: firstDirectory)
        _ = try await harness.port.stop()

        let secondDirectory = try Harness.makeDirectory()
        try await harness.start(directory: secondDirectory)
        _ = try await harness.port.stop()

        XCTAssertEqual(harness.gateway.aggregateBuildCount, 2, "по одной сборке на сеанс")
        XCTAssertTrue(harness.gateway.aggregateBuildArgs.allSatisfy(\.driftCompensation),
                      "компенсация дрейфа — true и во втором сеансе, не только в первом")
    }

    /// Возврат MEE-317 (третий круг): значение для НЕ опорного tap — чистая функция
    /// (`AggregateRuntime.nonReferenceDriftCompensationValue`), не требующая живого HAL.
    /// `buildComposition` целиком не тестируема в CI без TCC и настоящего tap-объекта — эта
    /// часть её решения тестируема, и здесь проверена напрямую.
    func test_k06_nonReferenceDriftCompensationValueMatchesFlag() {
        XCTAssertEqual(AggregateRuntime.nonReferenceDriftCompensationValue(true), 1)
        XCTAssertEqual(AggregateRuntime.nonReferenceDriftCompensationValue(false), 0)
    }
}
