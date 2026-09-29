//  AudioTrackReaderScaleTests — C-011 v7, инвариант 16 (IR-148, MEE-479): `offsetMs` — позиция
//  на шкале записи, где лежит кадр 0 файла; позиция в файле = позиция на шкале − `offsetMs`;
//  из файла ничего не отрезается. Векторы абзаца v7 — каждый отдельным тестом: кадры —
//  через `frameRange` (исходная частота, до передискретизации), поведение — на синтетических
//  CAF через публичный `read`.

import XCTest
import EngineKit
@testable import EngineXPCService

final class AudioTrackReaderScaleTests: AudioTrackReaderTestCase {

    private let rate = AudioTrackReader.outputSampleRate

    /// Вектор v7: `offsetMs = 1000`, `startMs = 3000`, `endMs = 4000`, 48 000 Гц → кадры
    /// 96 000…144 000. На файле: [0, 2000) мс файла — тишина, [2000, 3000) — синус; срез
    /// 3000…4000 на шкале записи — это ровно синус, а срез 1000…2000 — тишина.
    func testVectorOffset1000Slice3000To4000IsFrames96000To144000() throws {
        XCTAssertEqual(
            try AudioTrackReader.frameRange(
                startMs: 3_000, endMs: 4_000, offsetMs: 1_000, sampleRate: 48_000, fileLength: 1_000_000
            ),
            96_000..<144_000
        )

        let url = try SyntheticCAF.write(
            [SyntheticCAF.silence(ms: 2_000, channels: 2), SyntheticCAF.tone(ms: 1_000, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )
        let ref = try audioRef(url, channelCount: 2, offsetMs: 1_000)

        let tone = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 3_000, endMs: 4_000))
        let silent = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 1_000, endMs: 2_000))

        XCTAssertEqual(Double(tone.count), 16_000, accuracy: 1)
        let interior = 200..<15_800
        XCTAssertGreaterThan(SignalProbe.rms(tone, in: interior), 0.6)
        XCTAssertEqual(SignalProbe.frequency(tone, in: interior, sampleRate: rate), 440, accuracy: 3)
        XCTAssertEqual(Double(silent.count), 16_000, accuracy: 1)
        XCTAssertLessThan(SignalProbe.rms(silent, in: interior), 0.01)
    }

    /// Вектор v7: `offsetMs = 0`, 500 Гц, `startMs = 1` → кадр 1 (0,5 округляется от нуля).
    func testVectorHalfFrameRoundsAwayFromZero() throws {
        XCTAssertEqual(AudioTrackReader.frame(ms: 1, sampleRate: 500), 1)
        XCTAssertEqual(
            try AudioTrackReader.frameRange(startMs: 1, endMs: 3, offsetMs: 0, sampleRate: 500, fileLength: 100),
            1..<2
        )
        XCTAssertEqual(AudioTrackReader.frame(ms: -1, sampleRate: 500), -1, "от нуля и для отрицательных")
        XCTAssertEqual(AudioTrackReader.frame(ms: 1, sampleRate: 499), 0, "0,499 — к ближайшему, вниз")
    }

    /// Вектор v7: `offsetMs = 1000`, `startMs = 999` → `unsupportedRequest`.
    func testVectorSliceStartingBeforeOffsetIsUnsupportedRequest() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 2_000, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )
        let ref = try audioRef(url, channelCount: 2, offsetMs: 1_000)

        assertUnsupportedRequest(
            { try AudioTrackReader.read(AudioSlice(source: ref, startMs: 999, endMs: 2_000)) },
            contains: ["999", "1000"]
        )
    }

    /// Вектор v7: файл 10 с, срез 9000…11000 → кадры до конца файла, без ошибки. Последняя
    /// секунда файла — другой тон (880 Гц против 220 Гц): вырезка — ровно она, а не просто
    /// 16 000 отсчётов откуда-нибудь (MEE-491).
    func testVectorSliceRunningPastEndIsClampedToEndOfFile() throws {
        XCTAssertEqual(
            try AudioTrackReader.frameRange(
                startMs: 9_000, endMs: 11_000, offsetMs: 0, sampleRate: 48_000, fileLength: 480_000
            ),
            432_000..<480_000
        )

        let url = try SyntheticCAF.write(
            [
                SyntheticCAF.tone(ms: 9_000, hz: 220, amplitudes: [1]),
                SyntheticCAF.tone(ms: 1_000, hz: 880, amplitudes: [1])
            ],
            sampleRate: 48_000, channels: 1, to: directory
        )
        let ref = try audioRef(url, channelCount: 1, channel: .mic)
        let samples = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 9_000, endMs: 11_000))

        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 1)
        let interior = 200..<15_800
        XCTAssertGreaterThan(SignalProbe.rms(samples, in: interior), 0.6)
        XCTAssertEqual(SignalProbe.frequency(samples, in: interior, sampleRate: rate), 880, accuracy: 3)
    }

    /// Вектор v7: файл 10 с, срез 10000…11000 → ни одного кадра после обрезки → `unsupportedRequest`.
    func testVectorSliceEntirelyPastEndIsUnsupportedRequest() throws {
        let url = try tenSecondFile()
        let ref = try audioRef(url, channelCount: 1, channel: .mic)

        assertUnsupportedRequest { try AudioTrackReader.read(AudioSlice(source: ref, startMs: 10_000, endMs: 11_000)) }
    }

    /// Пустой срез (`endMs == startMs`) — тоже «ни одного кадра» → `unsupportedRequest`.
    func testEmptySliceIsUnsupportedRequest() throws {
        let url = try tenSecondFile()
        let ref = try audioRef(url, channelCount: 1, channel: .mic)

        assertUnsupportedRequest { try AudioTrackReader.read(AudioSlice(source: ref, startMs: 500, endMs: 500)) }
    }

    /// Из файла ничего не отрезается: `read(AudioRef)` отдаёт файл целиком при любом `offsetMs`.
    func testWholeTrackIgnoresOffsetMs() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 1_000, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )

        let atZero = try AudioTrackReader.read(audioRef(url, channelCount: 2, offsetMs: 0))
        let shifted = try AudioTrackReader.read(audioRef(url, channelCount: 2, offsetMs: 250))

        XCTAssertEqual(Double(shifted.count), 16_000, accuracy: 1)
        XCTAssertEqual(shifted, atZero)
    }

    private func tenSecondFile() throws -> URL {
        try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 10_000, hz: 440, amplitudes: [1])],
            sampleRate: 48_000, channels: 1, to: directory
        )
    }
}
