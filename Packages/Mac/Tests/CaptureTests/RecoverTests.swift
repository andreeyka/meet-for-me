//  К20 — recover идемпотентен и полон. План MEE-315. Не нуждается в живом сеансе: `recover`
//  читает то, что уже лежит на диске (контракт, §«Восстановление оборванной записи»).

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class RecoverTests: CaptureAsyncTestCase {

    /// Каталог с оборванным манифестом: трек написан напрямую через `TrackFile` (та же точка
    /// входа, что и харнесс-писатель К27б), файл не финализирован — как после `SIGKILL`.
    private func makeTruncatedRecording(
        frames: Int, sampleRate: Int = 48_000
    ) throws -> (directory: URL, recordingId: UUID) {
        let directory = try Harness.makeDirectory()
        let recordingId = UUID()
        let format = TrackFormat(sampleRate: sampleRate, channelCount: 1)
        let track = try TrackFile(directory: directory, channel: .mic, format: format)
        try track.append([Float](repeating: 0.2, count: frames))
        // Файл остаётся с `data`-размером -1 — намеренно: `TrackFile.finalize()` здесь не зовём,
        // как и не звал бы аварийно прерванный писатель.

        let trackDescriptor = try RecordingManifest.Track(channel: .mic, fileName: track.fileName,
                                                           sampleRate: sampleRate, channelCount: 1, format: "pcm-caf")
        let manifest = try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, tracks: [trackDescriptor],
            markers: [], capturedProcesses: [], captureGroupKey: nil, inputDevices: [], discontinuities: [],
            isFinalized: false
        )
        try ManifestWriter.writeAtomically(manifest, to: directory)
        return (directory, recordingId)
    }

    func test_k20_recoverFillsEndedAtAndTailDiscontinuity() async throws {
        let (directory, _) = try makeTruncatedRecording(frames: 48_000) // ровно 1 секунда
        let harness = Harness()

        let recovered = try await harness.port.recover(directory: directory)

        XCTAssertNotNil(recovered.endedAt)
        let durationMs = recovered.endedAt!.timeIntervalSince(recovered.startedAt) * 1000
        XCTAssertEqual(durationMs, 1000, accuracy: 1)
        let tail = try XCTUnwrap(recovered.discontinuities.last)
        XCTAssertEqual(tail.reason, .truncated)
        XCTAssertLessThanOrEqual(tail.gapMs, AudioCaptureLimits.truncatedTailBudgetMs)
        XCTAssertEqual(tail.atMs, 1000)
        XCTAssertTrue(recovered.markers.contains { $0.kind == .discontinuity && $0.atMs == 1000 })
    }

    func test_k20_secondRecoverIsIdempotent() async throws {
        let (directory, _) = try makeTruncatedRecording(frames: 24_000)
        let harness = Harness()

        let first = try await harness.port.recover(directory: directory)
        let bytesAfterFirst = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let second = try await harness.port.recover(directory: directory)
        let bytesAfterSecond = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))

        XCTAssertEqual(first, second, "второй вызов возвращает тот же манифест")
        XCTAssertEqual(first.discontinuities.count, 1)
        XCTAssertEqual(second.discontinuities.count, 1, "второй разрыв не дописан")
        XCTAssertEqual(bytesAfterFirst, bytesAfterSecond, "файл не переписан")
    }
}
