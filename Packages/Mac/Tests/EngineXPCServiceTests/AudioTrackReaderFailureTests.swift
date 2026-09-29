//  AudioTrackReaderFailureTests — C-011 v7, инвариант 17 (IR-148, MEE-479): файл, который нельзя
//  прочитать, — `audioUnreadable(path:)`; заголовок, не совпавший с `AudioRef`, —
//  `unsupportedRequest(message:)` с заявленным и найденным значениями, не `runtimeFailure`.

import XCTest
import EngineKit
import EngineXPCService

final class AudioTrackReaderFailureTests: AudioTrackReaderTestCase {

    /// Вектор v7: файла нет → `audioUnreadable(path:)`.
    func testVectorMissingFileIsAudioUnreadable() throws {
        let url = directory.appendingPathComponent("audio-system.caf")
        let ref = try audioRef(url, channelCount: 2)

        assertAudioUnreadable({ try AudioTrackReader.read(ref) }, path: url.path)
        assertAudioUnreadable(
            { try AudioTrackReader.read(AudioSlice(source: ref, startMs: 0, endMs: 100)) }, path: url.path
        )
    }

    /// Файл есть, но не разбирается как аудио → `audioUnreadable(path:)`.
    func testUnparsableFileIsAudioUnreadable() throws {
        let url = directory.appendingPathComponent("garbage.caf")
        try Data("это не CAF".utf8).write(to: url)

        let ref = try audioRef(url, channelCount: 2)
        assertAudioUnreadable({ try AudioTrackReader.read(ref) }, path: url.path)
    }

    /// Вектор v7: заголовок 44 100 при заявленных 48 000 → `unsupportedRequest`, в сообщении оба числа.
    func testVectorSampleRateMismatchIsUnsupportedRequestWithBothValues() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 100, hz: 440, amplitudes: [1, 1])],
            sampleRate: 44_100, channels: 2, to: directory
        )

        let ref = try audioRef(url, sampleRate: 48_000, channelCount: 2)
        assertUnsupportedRequest({ try AudioTrackReader.read(ref) }, contains: ["48000", "44100"])
    }

    /// Число каналов не совпало → то же, `unsupportedRequest` с обоими значениями.
    func testChannelCountMismatchIsUnsupportedRequestWithBothValues() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 100, hz: 440, amplitudes: [1])],
            sampleRate: 48_000, channels: 1, to: directory
        )

        let ref = try audioRef(url, channelCount: 2)
        assertUnsupportedRequest(
            { try AudioTrackReader.read(AudioSlice(source: ref, startMs: 0, endMs: 50)) },
            contains: ["channelCount AudioRef 2, файл 1"]
        )
    }
}
