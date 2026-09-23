//  К23, К24 — удержание системы, пауза не разрыв. План MEE-315.

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class PowerAndPauseTests: CaptureAsyncTestCase {

    // MARK: - К23. Удержание системы

    func test_k23_oneTokenPerSessionReleasedOnStop() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        XCTAssertEqual(harness.power.beginCount, 1)
        XCTAssertEqual(harness.power.liveTokenCount, 1)

        _ = try await harness.port.stop()
        XCTAssertEqual(harness.power.liveTokenCount, 0, "после stop живых токенов не остаётся")
    }

    func test_k23_failedStartLeavesNoLiveToken() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        let request = Harness.request(directory: directory, input: .none)

        async let started = harness.port.start(request)
        try await Task.sleep(nanoseconds: 20_000_000)
        harness.gateway.resolveTap(with: .permissionDenied)
        do {
            _ = try await started
            XCTFail("ожидался systemAudioDenied")
        } catch CaptureError.systemAudioDenied {}

        XCTAssertEqual(harness.power.liveTokenCount, 0, "токен вообще не берётся, пока start не дошёл до сборки")
    }

    // MARK: - К24. Пауза не разрыв

    func test_k24_pauseResumeDoesNotAdvanceScaleOrCreateDiscontinuity() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        try await harness.port.pause()
        try await harness.port.resume()

        let manifest = try await harness.port.stop()
        let pauseMarkers = manifest.markers.filter { $0.kind == .pause }
        let resumeMarkers = manifest.markers.filter { $0.kind == .resume }
        XCTAssertEqual(pauseMarkers.count, 1)
        XCTAssertEqual(resumeMarkers.count, 1)
        XCTAssertEqual(pauseMarkers.first?.atMs, resumeMarkers.first?.atMs, "шкала не продвинулась во время паузы")
        XCTAssertTrue(manifest.discontinuities.isEmpty, "пауза не порождает разрыва")
    }

    func test_k24_bufferDuringPauseIsNotWritten() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)

        try await harness.port.pause()
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        try await Task.sleep(nanoseconds: 20_000_000)
        try await harness.port.resume()

        let manifest = try await harness.port.stop()
        let micFrames = TrackFile.framesOnDisk(
            at: directory.appendingPathComponent("audio-mic.caf"),
            channelCount: manifest.tracks.first { $0.channel == .mic }?.channelCount ?? 1
        )
        XCTAssertEqual(micFrames, 0, "буфер, пришедший во время паузы, не записан")
    }
}
