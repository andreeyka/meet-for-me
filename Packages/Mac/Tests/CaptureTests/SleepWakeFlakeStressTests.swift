//  ВРЕМЕННЫЙ файл — MEE-365. Прогоняет сценарий
//  test_sleepWritesValidManifestToDiskImmediately (SleepWakeTests.swift) 50 раз подряд в одном
//  процессе CI, чтобы подтвердить, что правка (опрос диска вместо фиксированного
//  Task.sleep(10мс) — гонка со scheduling-задержкой powerEventsTask) убрала нестабильность, а
//  не просто спрятала её единственным прогоном. Убирается до слияния — лог CI прикладывается в
//  MEE-365 перед удалением этого файла.
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

            harness.power.emit(.willSleep)

            let onDisk = try await pollManifest(from: directory) { manifest in
                manifest.markers.contains { $0.kind == .sleep }
                    && manifest.markers.contains { $0.kind == .discontinuity }
                    && manifest.discontinuities.contains { $0.reason == .sleep }
            }
            XCTAssertTrue(onDisk.markers.contains { $0.kind == .sleep }, "повтор \(iteration)")
            XCTAssertTrue(onDisk.markers.contains { $0.kind == .discontinuity }, "повтор \(iteration)")
            XCTAssertTrue(onDisk.discontinuities.contains { $0.reason == .sleep }, "повтор \(iteration)")

            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 2_000))
            harness.power.emit(.didWake)
            try await Task.sleep(nanoseconds: 10_000_000)
            _ = try await harness.port.stop()
        }
    }

    /// Копия `SleepWakeTests.pollManifest` — намеренная: этот файл временный и удаляется
    /// целиком до слияния (MEE-365), общий хелпер под него заводить не имеет смысла.
    private func pollManifest(
        from directory: URL, until predicate: (RecordingManifest) -> Bool
    ) async throws -> RecordingManifest {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            if let manifest = try? ManifestWriter.read(from: directory), predicate(manifest) {
                return manifest
            }
            if ContinuousClock.now >= deadline {
                return try ManifestWriter.read(from: directory)
            }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}
