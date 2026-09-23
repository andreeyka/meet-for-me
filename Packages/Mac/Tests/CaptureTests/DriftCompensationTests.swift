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
}
