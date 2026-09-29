//  AudioTrackReaderTestSupport — синтетические `pcm-caf` для тестов `AudioTrackReader` (MEE-475):
//  генерируются в тесте во временной папке, без внешних файлов и без сети. Раскладка байт —
//  та же, что пишет захват (`Packages/Mac/Sources/Capture/TrackFile.swift`): `caff` v1,
//  `desc` lpcm Float32 LE interleaved, `data` с `mEditCount`; длина `data` — честная
//  (штатное закрытие) либо −1 (запись оборвана `SIGKILL`, К27(б) C-004).

import Foundation
import XCTest
import DomainCore
import EngineKit

enum SyntheticCAF {

    /// Один отрезок сигнала: `durationMs` миллисекунд синуса `frequency` Гц амплитуды
    /// `amplitudes[канал]`; `frequency == 0` — тишина.
    struct Segment {
        var durationMs: Int
        var frequency: Double
        var amplitudes: [Float]
    }

    static func tone(ms: Int, hz: Double, amplitudes: [Float]) -> Segment {
        Segment(durationMs: ms, frequency: hz, amplitudes: amplitudes)
    }

    static func silence(ms: Int, channels: Int) -> Segment {
        Segment(durationMs: ms, frequency: 0, amplitudes: Array(repeating: 0, count: channels))
    }

    /// Пишет CAF в `directory` и возвращает его адрес.
    static func write(
        _ segments: [Segment], sampleRate: Int, channels: Int,
        unknownLength: Bool = false, to directory: URL, name: String = "track.caf"
    ) throws -> URL {
        var interleaved: [Float] = []
        var frameIndex = 0
        for segment in segments {
            let count = segment.durationMs * sampleRate / 1000
            for _ in 0..<count {
                let phase = 2 * Double.pi * segment.frequency * Double(frameIndex) / Double(sampleRate)
                let value = Float(sin(phase))
                for channel in 0..<channels {
                    interleaved.append(value * segment.amplitudes[channel])
                }
                frameIndex += 1
            }
        }
        var data = header(sampleRate: sampleRate, channels: channels,
                          dataBytes: unknownLength ? nil : interleaved.count * 4)
        interleaved.withUnsafeBytes { data.append(contentsOf: $0) }
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func header(sampleRate: Int, channels: Int, dataBytes: Int?) -> Data {
        var data = Data("caff".utf8)
        data.appendBE(UInt16(1))
        data.appendBE(UInt16(0))
        data.append(contentsOf: Array("desc".utf8))
        data.appendBE(Int64(32))
        data.appendBE(Double(sampleRate).bitPattern)
        data.append(contentsOf: Array("lpcm".utf8))
        data.appendBE(UInt32(0x1 | 0x2))            // Float | LittleEndian
        data.appendBE(UInt32(4 * channels))
        data.appendBE(UInt32(1))
        data.appendBE(UInt32(channels))
        data.appendBE(UInt32(32))
        data.append(contentsOf: Array("data".utf8))
        data.appendBE(dataBytes.map { Int64($0 + 4) } ?? Int64(-1))   // +4 — mEditCount
        data.appendBE(UInt32(0))
        return data
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

enum SignalProbe {

    /// Частота по числу переходов через ноль на `samples[range]`.
    static func frequency(_ samples: [Float], in range: Range<Int>, sampleRate: Int) -> Double {
        var crossings = 0
        for index in range.dropFirst() where (samples[index - 1] < 0) != (samples[index] < 0) {
            crossings += 1
        }
        return Double(crossings) / 2 / (Double(range.count) / Double(sampleRate))
    }

    static func rms(_ samples: [Float], in range: Range<Int>) -> Float {
        let slice = samples[range]
        return (slice.reduce(0) { $0 + $1 * $1 } / Float(slice.count)).squareRoot()
    }

    static func peak(_ samples: [Float], in range: Range<Int>) -> Float {
        samples[range].reduce(0) { max($0, abs($1)) }
    }
}

/// Временная папка теста — удаляется в `tearDown`.
class AudioTrackReaderTestCase: XCTestCase {
    private(set) var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioTrackReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func audioRef(
        _ url: URL, sampleRate: Int = 48_000, channelCount: Int, offsetMs: Int = 0,
        channel: RecordingManifest.Channel = .system
    ) throws -> AudioRef {
        try AudioRef(
            recordingId: UUID(), channel: channel, fileURL: url,
            sampleRate: sampleRate, channelCount: channelCount, offsetMs: offsetMs
        )
    }

    /// `unsupportedRequest(message:)`, и в `message` — каждый из `fragments` (C-011 v7, инв. 16, 17).
    func assertUnsupportedRequest(
        _ body: () throws -> [Float], contains fragments: [String] = [],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            guard case EngineError.unsupportedRequest(let message) = error else {
                return XCTFail("ожидался EngineError.unsupportedRequest, получено \(error)", file: file, line: line)
            }
            for fragment in fragments {
                XCTAssertTrue(
                    message.contains(fragment), "«\(message)» не содержит «\(fragment)»", file: file, line: line
                )
            }
        }
    }

    /// `audioUnreadable(path:)` ровно с путём из `fileURL` (C-011 v7, инв. 17).
    func assertAudioUnreadable(
        _ body: () throws -> [Float], path: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { error in
            XCTAssertEqual(error as? EngineError, .audioUnreadable(path: path), file: file, line: line)
        }
    }
}
