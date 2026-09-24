//  ВРЕМЕННЫЙ файл — MEE-365, малый возврат. Прогоняет сценарий
//  test_sleepWritesValidManifestToDiskImmediately (SleepWakeTests.swift) 50 раз подряд в одном
//  процессе CI на новой голове (детерминированное ожидание через
//  performAndAwaitNextPowerEvent вместо фиксированной паузы) — подтверждает, что правка не
//  просто спрятала нестабильность одним удачным прогоном. Убирается до слияния — лог CI
//  прикладывается в MEE-365 перед удалением этого файла.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class SleepWakeFlakeStressTests: CaptureAsyncTestCase {
    override func invokeTest() {
        executionTimeAllowance = 60
        super.invokeTest()
    }

    func test_sleepWritesValidManifestToDiskImmediately_50Repeats() async throws {
        for iteration in 1...50 {
            let harness = Harness()
            let directory = try Harness.makeDirectory()
            try await harness.start(directory: directory)
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
            try await Task.sleep(nanoseconds: 10_000_000)

            await harness.port.performAndAwaitNextPowerEvent { harness.power.emit(.willSleep) }

            let onDisk = try ManifestWriter.read(from: directory)
            XCTAssertTrue(onDisk.markers.contains { $0.kind == .sleep }, "повтор \(iteration)")
            XCTAssertTrue(onDisk.markers.contains { $0.kind == .discontinuity }, "повтор \(iteration)")
            XCTAssertTrue(onDisk.discontinuities.contains { $0.reason == .sleep }, "повтор \(iteration)")

            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 2_000))
            harness.power.emit(.didWake)
            try await Task.sleep(nanoseconds: 10_000_000)
            _ = try await harness.port.stop()
        }
    }
}
