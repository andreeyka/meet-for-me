//  AudioTrackReaderTests — MEE-475, «Готовность»: чтение `pcm-caf` 48 кГц в 16 кГц моно Float32
//  на синтетических CAF (синус известной частоты), сгенерированных в тесте во временной папке.
//  Формат и длина результата, потоковое чтение, CAF с длиной −1. Шкала вырезки (C-011 v7,
//  инв. 16) — `AudioTrackReaderScaleTests`, отказы (инв. 17) — `AudioTrackReaderFailureTests`.

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
        XCTAssertEqual(Double(slice.count), 8_000, accuracy: 1, "конец среза обрезан по концу файла")
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
