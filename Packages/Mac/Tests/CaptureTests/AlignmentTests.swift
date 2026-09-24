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
        // MEE-374 (аудит MEE-377): `gateway.feed`/`emit` синхронно доходят до записи на диск —
        // `handleBuffer` без единого `await`/`Task` внутри (см. `AudioCaptureImplBuffers.swift`),
        // пауз между вызовами шва не нужно.
        harness.gateway.feed(.samples(.mic, frameCount: 480, channelCount: 1, hostTime: 1_000))
        harness.gateway.feed(.samples(.system, frameCount: 480, channelCount: 2, hostTime: 1_010))

        harness.gateway.emit(.tapInvalidated(atHostTime: 2_000))

        // После разрыва: первый пришедший буфер (мик) разрешает `pendingRebuild` — `resolveRebuild`
        // досыпает ОДНО и то же число кадров тишины ОБОИМ трекам за один вызов (общий `gapMs`,
        // общий цикл по `[micTrack, systemTrack]`), затем второй буфер (систем) просто дописывает
        // данные — `pendingRebuild` уже `nil`. Значит расхождение кадров возможно только от РАЗНЫХ
        // порций реальных данных, поданных каждому треку, а не от заполнения разрыва.
        harness.gateway.feed(.samples(.mic, frameCount: 240, channelCount: 1, hostTime: 2_050))
        harness.gateway.feed(.samples(.system, frameCount: 240, channelCount: 2, hostTime: 2_050))

        // Возврат MEE-317 (24.09): проверка сразу после разрешения разрыва, а не только на итоговом
        // файле — точное равенство, а не допуск в 512 кадров на весь прогон (тот допуск маскировал
        // бы именно расхождение, случившееся на самом разрыве, потерявшись в куда большем объёме
        // данных до него).
        let micFramesAfterGap = TrackFile.framesOnDisk(
            at: directory.appendingPathComponent(TrackFile.fileName(for: .mic)), channelCount: 1
        )
        let systemFramesAfterGap = TrackFile.framesOnDisk(
            at: directory.appendingPathComponent(TrackFile.fileName(for: .system)), channelCount: 2
        )
        XCTAssertEqual(micFramesAfterGap, systemFramesAfterGap,
                       "оба трека получили один и тот же `gapMs` одним вызовом resolveRebuild — точное равенство")

        let manifest = try await harness.port.stop()
        let micTrack = try XCTUnwrap(manifest.tracks.first { $0.channel == .mic })
        let systemTrack = try XCTUnwrap(manifest.tracks.first { $0.channel == .system })
        let micFrames = TrackFile.framesOnDisk(at: directory.appendingPathComponent(micTrack.fileName),
                                               channelCount: micTrack.channelCount)
        let systemFrames = TrackFile.framesOnDisk(at: directory.appendingPathComponent(systemTrack.fileName),
                                                  channelCount: systemTrack.channelCount)
        XCTAssertEqual(micFrames, systemFrames, "итоговые файлы — точное равенство, те же порции обоим трекам")
    }
}
