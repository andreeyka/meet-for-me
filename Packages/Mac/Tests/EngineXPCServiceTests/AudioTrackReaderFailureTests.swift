//  AudioTrackReaderFailureTests — MEE-475, отказы `AudioTrackReader` через `EngineError` (C-011)
//  без нового случая: файла нет или он не читается, заголовок не совпадает с `AudioRef`.

import XCTest
import EngineKit
import EngineXPCService

final class AudioTrackReaderFailureTests: AudioTrackReaderTestCase {

    func testMissingFileIsRuntimeFailureWithPath() throws {
        let url = directory.appendingPathComponent("audio-system.caf")

        let ref = try audioRef(url, channelCount: 2)
        assertRuntimeFailure({ try AudioTrackReader.read(ref) }, contains: [url.path])
    }

    func testUnreadableFileIsRuntimeFailureWithPath() throws {
        let url = directory.appendingPathComponent("garbage.caf")
        try Data("это не CAF".utf8).write(to: url)

        let ref = try audioRef(url, channelCount: 2)
        assertRuntimeFailure({ try AudioTrackReader.read(ref) }, contains: [url.path])
    }

    func testSampleRateMismatchIsRuntimeFailureWithBothValues() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 100, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )

        let ref = try audioRef(url, sampleRate: 44_100, channelCount: 2)
        assertRuntimeFailure({ try AudioTrackReader.read(ref) }, contains: [url.path, "44100", "48000"])
    }

    func testChannelCountMismatchIsRuntimeFailureWithBothValues() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 100, hz: 440, amplitudes: [1])],
            sampleRate: 48_000, channels: 1, to: directory
        )

        let ref = try audioRef(url, channelCount: 2)
        assertRuntimeFailure(
            { try AudioTrackReader.read(AudioSlice(source: ref, startMs: 0, endMs: 50)) },
            contains: [url.path, "channelCount AudioRef 2, файл 1"]
        )
    }
}
