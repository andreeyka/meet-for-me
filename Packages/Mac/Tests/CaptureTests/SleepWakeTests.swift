//  Сон/пробуждение (§«Поведение», возврат части 1 — п. 6): источник — `.willSleep`/`.didWake`
//  C-008 (`PowerPort.events()`), после `.didWake` порт берёт НОВЫЙ токен удержания.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class SleepWakeTests: CaptureAsyncTestCase {

    func test_sleepMarksAndDiscontinuityWakeTakesNewToken() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        try await Task.sleep(nanoseconds: 10_000_000)

        XCTAssertEqual(harness.power.beginActivityCallCount, 1)

        harness.power.emit(.willSleep)
        try await Task.sleep(nanoseconds: 10_000_000)
        harness.power.emit(.didWake)
        try await Task.sleep(nanoseconds: 10_000_000)

        // «После .didWake порт берёт новый токен удержания» — дословно контракт: старый
        // закрыт (недействителен вместе со сном), взят новый — два вызова beginActivity на сеанс.
        XCTAssertEqual(harness.power.beginActivityCallCount, 2, "новый токен взят после пробуждения")
        XCTAssertEqual(harness.power.liveActivities.count, 1, "старый закрыт, живой ровно один")

        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 2_000))
        let manifest = try await harness.port.stop()

        XCTAssertTrue(manifest.markers.contains { $0.kind == .sleep })
        XCTAssertTrue(manifest.markers.contains { $0.kind == .wake })
        XCTAssertTrue(manifest.discontinuities.contains { $0.reason == .sleep })
        XCTAssertEqual(harness.power.liveActivities.count, 0, "stop снимает и новый токен")
    }
}
