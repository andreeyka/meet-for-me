//  ВРЕМЕННЫЙ файл — MEE-371. Прогоняет все четыре сценария `SleepWakeTests.swift` по 50 раз
//  подряд в одном процессе CI на новой голове (детерминированное ожидание подписки через
//  `awaitPowerEventsSubscribed()` вместо фиксированной паузы перед первым `power.emit`, плюс
//  пробуждение ожидающих `performAndAwaitNextPowerEvent` на всех ветках цикла обработки, не
//  только на ветке `.running`) — подтверждает, что правка не просто спрятала нестабильность
//  одним удачным прогоном. Убирается до слияния — лог CI прикладывается в MEE-371 перед
//  удалением этого файла.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class SleepWakeFlakeStressTests: CaptureAsyncTestCase {
    override func invokeTest() {
        executionTimeAllowance = 120
        super.invokeTest()
    }

    func test_sleepMarksAndDiscontinuityWakeTakesNewToken_50Repeats() async throws {
        for iteration in 1...50 {
            let harness = Harness()
            let directory = try Harness.makeDirectory()
            try await harness.start(directory: directory)
            await harness.port.awaitPowerEventsSubscribed()
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
            try await Task.sleep(nanoseconds: 10_000_000)

            XCTAssertEqual(harness.power.beginActivityCallCount, 1, "повтор \(iteration)")

            harness.power.emit(.willSleep)
            try await Task.sleep(nanoseconds: 10_000_000)
            harness.power.emit(.didWake)
            try await Task.sleep(nanoseconds: 10_000_000)

            XCTAssertEqual(harness.power.beginActivityCallCount, 2, "повтор \(iteration)")
            XCTAssertEqual(harness.power.liveActivities.count, 1, "повтор \(iteration)")

            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 2_000))
            let manifest = try await harness.port.stop()

            XCTAssertTrue(manifest.markers.contains { $0.kind == .sleep }, "повтор \(iteration)")
            XCTAssertTrue(manifest.markers.contains { $0.kind == .wake }, "повтор \(iteration)")
            XCTAssertTrue(manifest.discontinuities.contains { $0.reason == .sleep }, "повтор \(iteration)")
            XCTAssertEqual(harness.power.liveActivities.count, 0, "повтор \(iteration)")
        }
    }

    func test_sleepThenStopBeforeWakeDoesNotThrow_50Repeats() async throws {
        for iteration in 1...50 {
            let harness = Harness()
            let directory = try Harness.makeDirectory()
            try await harness.start(directory: directory)
            await harness.port.awaitPowerEventsSubscribed()
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
            try await Task.sleep(nanoseconds: 10_000_000)

            harness.power.emit(.willSleep)
            try await Task.sleep(nanoseconds: 10_000_000)

            let manifest = try await harness.port.stop()
            XCTAssertTrue(manifest.markers.contains { $0.kind == .sleep }, "повтор \(iteration)")
            let discontinuityMarkers = manifest.markers.filter { $0.kind == .discontinuity }
            XCTAssertEqual(discontinuityMarkers.count, 1, "повтор \(iteration)")
            XCTAssertEqual(manifest.discontinuities.filter { $0.reason == .sleep }.count, 1, "повтор \(iteration)")
        }
    }

    func test_sleepWritesValidManifestToDiskImmediately_50Repeats() async throws {
        for iteration in 1...50 {
            let harness = Harness()
            let directory = try Harness.makeDirectory()
            try await harness.start(directory: directory)
            await harness.port.awaitPowerEventsSubscribed()
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

    func test_sleepDuringPendingRebuildDoesNotOrphanDiscontinuityMarker_50Repeats() async throws {
        for iteration in 1...50 {
            let harness = Harness()
            let directory = try Harness.makeDirectory()
            try await harness.start(directory: directory)
            await harness.port.awaitPowerEventsSubscribed()
            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
            try await Task.sleep(nanoseconds: 10_000_000)

            harness.gateway.emit(.microphoneChanged(
                MicrophoneHandle(uid: "airpods", name: "AirPods", channelCount: 1), atHostTime: 2_000
            ))
            try await Task.sleep(nanoseconds: 10_000_000)

            harness.power.emit(.willSleep)
            try await Task.sleep(nanoseconds: 10_000_000)

            harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 2_100))
            try await Task.sleep(nanoseconds: 10_000_000)

            let manifest = try await harness.port.stop()
            XCTAssertTrue(manifest.markers.contains { $0.kind == .sleep }, "повтор \(iteration)")
            let discontinuityMarkers = manifest.markers.filter { $0.kind == .discontinuity }
            XCTAssertEqual(discontinuityMarkers.count, 1, "повтор \(iteration)")
            XCTAssertEqual(manifest.discontinuities.count, 1, "повтор \(iteration)")
            XCTAssertEqual(manifest.discontinuities.first?.reason, .rebuild, "повтор \(iteration)")
        }
    }
}
