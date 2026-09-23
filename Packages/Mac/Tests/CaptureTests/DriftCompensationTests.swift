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
        // ещё не разрешённой первой.
        for index in 0..<10 {
            harness.gateway.emit(.tapInvalidated(atHostTime: UInt64(1_000 + index)))
            try await Task.sleep(nanoseconds: 5_000_000)
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: UInt64(2_000 + index)))
            try await Task.sleep(nanoseconds: 5_000_000)
        }

        _ = try await harness.port.stop()

        XCTAssertEqual(harness.gateway.aggregateBuildCount, 11, "старт + десять пересборок")
        XCTAssertTrue(harness.gateway.aggregateBuildArgs.allSatisfy(\.driftCompensation),
                      "компенсация дрейфа — true на каждом вызове buildAggregate без исключений")
    }
}
