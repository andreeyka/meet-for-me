//  К22 — выравнивание треков через разрыв. План MEE-315.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class AlignmentTests: CaptureAsyncTestCase {

    func test_k22_tracksStayAlignedAcrossADiscontinuity() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        // До разрыва: 480 кадров на оба трека одним и тем же host time.
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        harness.gateway.feed(.samples(.system, frameCount: 480, channelCount: 2, hostTime: 1_010))
        try await Task.sleep(nanoseconds: 10_000_000)

        harness.gateway.emit(.tapInvalidated(atHostTime: 2_000))
        try await Task.sleep(nanoseconds: 10_000_000)

        // После разрыва: снова равные порции на оба трека — первый буфер каждого разрешает
        // разрыв своего трека независимо (resolveRebuild зовётся по первому пришедшему буферу).
        harness.gateway.feed(.samples(.mic, frameCount: 240, channelCount: 1, hostTime: 2_050))
        harness.gateway.feed(.samples(.system, frameCount: 240, channelCount: 2, hostTime: 2_050))
        try await Task.sleep(nanoseconds: 10_000_000)

        let manifest = try await harness.port.stop()
        let micTrack = try XCTUnwrap(manifest.tracks.first { $0.channel == .mic })
        let systemTrack = try XCTUnwrap(manifest.tracks.first { $0.channel == .system })
        let micFrames = TrackFile.framesOnDisk(at: directory.appendingPathComponent(micTrack.fileName),
                                               channelCount: micTrack.channelCount)
        let systemFrames = TrackFile.framesOnDisk(at: directory.appendingPathComponent(systemTrack.fileName),
                                                  channelCount: systemTrack.channelCount)
        // Одна и та же позиция шкалы после разрыва — оба трека получили одинаковую тишину на
        // заполнение и одинаковые порции реальных данных; расхождение — только на IO-буфер (512).
        XCTAssertLessThanOrEqual(abs(micFrames - systemFrames), 512, "допуск — не больше одного IO-буфера")
    }
}
