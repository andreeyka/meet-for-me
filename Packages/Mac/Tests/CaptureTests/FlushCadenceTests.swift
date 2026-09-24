//  К27(а) — частота сброса на диск не реже truncatedTailBudgetMs, пока идут данные (инвариант 26).
//  Способ А через шов: наблюдаем TrackFile.lastFlushAt напрямую (internal, @testable) — сброс
//  на первом буфере всегда, дальше только когда разрыв host time достиг бюджета. План MEE-315.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class FlushCadenceTests: CaptureAsyncTestCase {

    func test_k27a_flushHappensOnFirstBufferThenNotBeforeBudgetThenAtBudget() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        let budget = UInt64(AudioCaptureLimits.truncatedTailBudgetMs)

        // MEE-374 (аудит MEE-377): `feed` синхронно доходит до `TrackFile.flush` — пауз не нужно.
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        let session1 = try harness.port.currentSession()
        let firstFlush = try XCTUnwrap(session1.micTrack).lastFlushAt
        XCTAssertEqual(firstFlush, 1_000, "первый буфер сбрасывается всегда")

        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000 + budget - 1))
        let session2 = try harness.port.currentSession()
        XCTAssertEqual(try XCTUnwrap(session2.micTrack).lastFlushAt, 1_000, "разрыв меньше бюджета — сброса ещё нет")

        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000 + budget))
        let session3 = try harness.port.currentSession()
        XCTAssertEqual(try XCTUnwrap(session3.micTrack).lastFlushAt, 1_000 + budget,
                       "разрыв достиг бюджета — сброс")
    }
}
