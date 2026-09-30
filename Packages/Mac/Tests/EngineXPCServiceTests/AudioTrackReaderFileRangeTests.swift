//  AudioTrackReaderFileRangeTests — MEE-504 (Z6): вход порта `GigaAMAudioSource` поверх
//  `AudioTrackReader` — длительность файла и чтение диапазона ВРЕМЕНИ В ФАЙЛЕ (без `offsetMs`).

import XCTest
import EngineKit
@testable import EngineXPCService

final class AudioTrackReaderFileRangeTests: AudioTrackReaderTestCase {

    func testDurationIsFileLengthInMillisecondsIgnoringOffset() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 2_500, hz: 440, amplitudes: [1, 1])], sampleRate: 48_000, channels: 2, to: directory
        )
        XCTAssertEqual(try AudioTrackReader.durationMs(of: audioRef(url, channelCount: 2)), 2_500)
        XCTAssertEqual(try AudioTrackReader.durationMs(of: audioRef(url, channelCount: 2, offsetMs: 7_000)), 2_500)
    }

    func testDurationDropsPartialMillisecond() throws {
        // 1000 мс + 47 кадров при 48 кГц (< 1 мс) — длительность 1000.
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 1_000, hz: 440, amplitudes: [1])], sampleRate: 48_000, channels: 1, to: directory
        )
        var data = try Data(contentsOf: url)
        data.append(Data(count: 47 * 4))
        try data.write(to: url)
        XCTAssertEqual(try AudioTrackReader.durationMs(of: audioRef(url, channelCount: 1)), 1_000)
    }

    func testDurationFailuresFollowInvariant17() throws {
        let missing = directory.appendingPathComponent("nope.caf")
        XCTAssertThrowsError(try AudioTrackReader.durationMs(of: audioRef(missing, channelCount: 2))) {
            XCTAssertEqual($0 as? EngineError, .audioUnreadable(path: missing.path))
        }
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 100, hz: 440, amplitudes: [1])], sampleRate: 48_000, channels: 1, to: directory
        )
        XCTAssertThrowsError(try AudioTrackReader.durationMs(of: audioRef(url, channelCount: 2))) {
            guard case EngineError.unsupportedRequest = $0 else { return XCTFail("\($0)") }
        }
    }

    /// [0; 2000) мс файла — тишина, [2000; 3000) — синус. С `offsetMs = 5000` диапазон файла
    /// 2000..<3000 — это синус (сдвиг на шкалу записи делает сам адаптер), а 1000..<2000 — тишина.
    func testFileRangeIsShiftedByOffsetOntoSlice() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.silence(ms: 2_000, channels: 2), SyntheticCAF.tone(ms: 1_000, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )
        let ref = try audioRef(url, channelCount: 2, offsetMs: 5_000)
        let tone = try AudioTrackReader.read(ref, fromMs: 2_000, toMs: 3_000)
        let silent = try AudioTrackReader.read(ref, fromMs: 1_000, toMs: 2_000)
        let sliced = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 7_000, endMs: 8_000))

        XCTAssertEqual(tone, sliced)
        XCTAssertEqual(Double(tone.count), 16_000, accuracy: 1)
        XCTAssertGreaterThan(SignalProbe.rms(tone, in: 200..<15_800), 0.6)
        XCTAssertLessThan(SignalProbe.rms(silent, in: 200..<15_800), 0.01)
    }

    func testFileRangePastEndIsClampedToEndOfFile() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 1_500, hz: 440, amplitudes: [1])], sampleRate: 48_000, channels: 1, to: directory
        )
        let samples = try AudioTrackReader.read(audioRef(url, channelCount: 1), fromMs: 1_000, toMs: 30_000)
        XCTAssertEqual(Double(samples.count), 8_000, accuracy: 1)
    }

    func testRangeThatIsNotASliceIsUnsupportedRequest() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 1_000, hz: 440, amplitudes: [1])], sampleRate: 48_000, channels: 1, to: directory
        )
        let ref = try audioRef(url, channelCount: 1)
        assertUnsupportedRequest({ try AudioTrackReader.read(ref, fromMs: 500, toMs: 500) })
        assertUnsupportedRequest({ try AudioTrackReader.read(ref, fromMs: 2_000, toMs: 3_000) })
    }
}
