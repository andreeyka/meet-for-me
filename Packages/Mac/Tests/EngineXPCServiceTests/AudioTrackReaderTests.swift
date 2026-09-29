//  AudioTrackReaderTests — MEE-475, «Готовность»: чтение `pcm-caf` 48 кГц в 16 кГц моно Float32
//  на синтетических CAF (синус известной частоты), сгенерированных в тесте во временной папке.

import XCTest
import EngineKit
import EngineXPCService

final class AudioTrackReaderTests: AudioTrackReaderTestCase {

    private let rate = AudioTrackReader.outputSampleRate

    /// 48 кГц стерео → 16 кГц моно: длина ±1 кадр, частота сохранена; сведение — среднее
    /// каналов (левый 0.8, правый 0.4 → 0.6).
    func testStereo48kBecomesMono16kWithLengthAndFrequencyKept() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 1_000, hz: 440, amplitudes: [0.8, 0.4])],
            sampleRate: 48_000, channels: 2, to: directory
        )

        let samples = try AudioTrackReader.read(audioRef(url, channelCount: 2))

        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 1)
        let interior = 400..<(samples.count - 400)
        XCTAssertEqual(SignalProbe.frequency(samples, in: interior, sampleRate: rate), 440, accuracy: 3)
        XCTAssertEqual(SignalProbe.peak(samples, in: interior), 0.6, accuracy: 0.01)
    }

    /// Микрофон — моно 48 кГц: то же, без сведения.
    func testMono48kBecomesMono16k() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 500, hz: 1_000, amplitudes: [0.5])],
            sampleRate: 48_000, channels: 1, to: directory
        )

        let samples = try AudioTrackReader.read(audioRef(url, channelCount: 1, channel: .mic))

        XCTAssertEqual(Double(samples.count), 8_000, accuracy: 1)
        let interior = 400..<(samples.count - 400)
        XCTAssertEqual(SignalProbe.frequency(samples, in: interior, sampleRate: rate), 1_000, accuracy: 5)
        XCTAssertEqual(SignalProbe.peak(samples, in: interior), 0.5, accuracy: 0.01)
    }

    /// Потоковое чтение: запись длиннее блока чтения (секунда) — длина и частота держатся, на
    /// стыках блоков нет разрывов (соседние отсчёты синуса 440 Гц при 16 кГц отличаются не
    /// больше чем на 2π·440/16000 ≈ 0.173 амплитуды).
    func testLongRecordingIsReadInBlocksWithoutSeams() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 5_300, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )

        let samples = try AudioTrackReader.read(audioRef(url, channelCount: 2))

        XCTAssertEqual(Double(samples.count), 84_800, accuracy: 1)
        let interior = 400..<(samples.count - 400)
        XCTAssertEqual(SignalProbe.frequency(samples, in: interior, sampleRate: rate), 440, accuracy: 1)
        let maxStep = interior.dropFirst().reduce(Float(0)) { max($0, abs(samples[$1] - samples[$1 - 1])) }
        XCTAssertLessThan(maxStep, 0.18)
    }

    /// `offsetMs`: образцы файла до смещения не отдаются. Файл — 250 мс тишины, затем 750 мс
    /// синуса; при `offsetMs == 250` результат короче на 250 мс и начинается сразу с синуса.
    func testOffsetMsDropsSamplesBeforeOffset() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.silence(ms: 250, channels: 2), SyntheticCAF.tone(ms: 750, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )

        let whole = try AudioTrackReader.read(audioRef(url, channelCount: 2))
        let shifted = try AudioTrackReader.read(audioRef(url, channelCount: 2, offsetMs: 250))

        XCTAssertEqual(Double(whole.count), 16_000, accuracy: 1)
        XCTAssertEqual(Double(shifted.count), 12_000, accuracy: 1)
        XCTAssertLessThan(SignalProbe.rms(whole, in: 100..<3_800), 0.01, "без смещения начало — тишина")
        XCTAssertGreaterThan(SignalProbe.rms(shifted, in: 100..<3_800), 0.6, "со смещением начало — синус")
    }

    /// Отрезок `AudioSlice` — на шкале дорожки после `offsetMs`. Файл: 500 мс тишины, 500 мс
    /// синуса; `offsetMs == 250` — дорожка: [0, 250) тишина, [250, 750) синус.
    func testAudioSliceIsOnTrackScaleAfterOffset() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.silence(ms: 500, channels: 2), SyntheticCAF.tone(ms: 500, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )
        let ref = try audioRef(url, channelCount: 2, offsetMs: 250)

        let silent = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 0, endMs: 200))
        let tone = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 300, endMs: 700))

        XCTAssertEqual(Double(silent.count), 3_200, accuracy: 1)
        XCTAssertEqual(Double(tone.count), 6_400, accuracy: 1)
        XCTAssertLessThan(SignalProbe.rms(silent, in: 100..<3_100), 0.01)
        let interior = 200..<6_200
        XCTAssertGreaterThan(SignalProbe.rms(tone, in: interior), 0.6)
        XCTAssertEqual(SignalProbe.frequency(tone, in: interior, sampleRate: rate), 440, accuracy: 5)
    }

    /// Хвост вырезки за концом файла нулями не дополняется; пустая вырезка — `[]`.
    func testAudioSliceIsClampedToEndOfFileAndEmptySliceIsEmpty() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 1_000, hz: 440, amplitudes: [1])],
            sampleRate: 48_000, channels: 1, to: directory
        )
        let ref = try audioRef(url, channelCount: 1, channel: .mic)

        let tail = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 750, endMs: 5_000))
        let beyond = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 2_000, endMs: 3_000))
        let empty = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 500, endMs: 500))

        XCTAssertEqual(Double(tail.count), 4_000, accuracy: 1)
        XCTAssertEqual(beyond, [])
        XCTAssertEqual(empty, [])
    }

    /// CAF с `data`-чанком длины −1 (запись оборвана `SIGKILL`, К27(б) C-004) читается до
    /// конца файла, а не отказом — тот же результат, что у честно закрытого файла.
    func testUnknownLengthCAFIsReadToEndOfFile() throws {
        let segments = [SyntheticCAF.tone(ms: 1_500, hz: 440, amplitudes: [0.8, 0.4])]
        let open = try SyntheticCAF.write(
            segments, sampleRate: 48_000, channels: 2, unknownLength: true, to: directory, name: "open.caf"
        )
        let closed = try SyntheticCAF.write(
            segments, sampleRate: 48_000, channels: 2, to: directory, name: "closed.caf"
        )

        let fromOpen = try AudioTrackReader.read(audioRef(open, channelCount: 2))
        let fromClosed = try AudioTrackReader.read(audioRef(closed, channelCount: 2))

        XCTAssertEqual(Double(fromOpen.count), 24_000, accuracy: 1)
        XCTAssertEqual(fromOpen, fromClosed)
        let openRef = try audioRef(open, channelCount: 2)
        let slice = try AudioTrackReader.read(AudioSlice(source: openRef, startMs: 1_000, endMs: 9_000))
        XCTAssertEqual(Double(slice.count), 8_000, accuracy: 1)
    }

    /// `SIGKILL` посреди записи блока оставляет неполный последний кадр: он отбрасывается,
    /// всё до него читается.
    func testUnknownLengthCAFWithTornLastFrameIsReadUpToIt() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 1_000, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, unknownLength: true, to: directory
        )
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x00, 0x00, 0x80]))
        try handle.close()

        let samples = try AudioTrackReader.read(audioRef(url, channelCount: 2))

        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 1)
    }
}
