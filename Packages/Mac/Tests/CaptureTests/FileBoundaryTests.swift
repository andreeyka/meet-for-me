//  К21 — граница записи: точный список файлов в каталоге, ни одного вне него; символьная
//  половина — нет ссылок на GRDB/БД (способ А+механически, план MEE-315).

import DomainCore
import Foundation
import XCTest
@testable import Capture

final class FileBoundaryTests: CaptureAsyncTestCase {

    func test_k21_directoryContainsExactlyTheExpectedFilesAfterStop() async throws {
        let harness = Harness()
        let directory = try Harness.makeDirectory()
        try await harness.start(directory: directory)
        _ = try await harness.port.stop()

        let files = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(files, ["audio-mic.caf", "audio-system.caf", "manifest.json"])
    }

    func test_k21_directoryContainsExactlyTheExpectedFilesAfterRecover() async throws {
        let directory = try Harness.makeDirectory()
        let recordingId = UUID()
        let format = TrackFormat(sampleRate: 48_000, channelCount: 1)
        let track = try TrackFile(directory: directory, channel: .mic, format: format)
        try track.append([Float](repeating: 0, count: 480))
        let descriptor = try RecordingManifest.Track(channel: .mic, fileName: track.fileName, sampleRate: 48_000,
                                                      channelCount: 1, format: "pcm-caf")
        let manifest = try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000), endedAt: nil, tracks: [descriptor], markers: [],
            capturedProcesses: [], captureGroupKey: nil, inputDevices: [], discontinuities: [], isFinalized: false
        )
        try ManifestWriter.writeAtomically(manifest, to: directory)

        _ = try await Harness().port.recover(directory: directory)

        let files = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(files, ["audio-mic.caf", "manifest.json"], "recover не создаёт файлов вне уже бывших")
    }

    /// Способ Б/механически: нет ссылок на GRDB и на типы прямой работы с БД — тот же способ,
    /// каким `ModuleTextTests` проверяет К19.
    func test_k21_noDatabaseSymbolsInSources() throws {
        let files = try CaptureSources.sources()
        for needle in ["GRDB", "import SQLite", "sqlite3_"] {
            let guilty = files.filter { $0.text.contains(needle) }.map(\.name)
            XCTAssertEqual(guilty, [], needle)
        }
    }
}
