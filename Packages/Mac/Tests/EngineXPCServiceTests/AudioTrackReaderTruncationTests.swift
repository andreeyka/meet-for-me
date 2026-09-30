//  AudioTrackReaderTruncationTests — MEE-491 (бэклог приёмки MEE-475): дорожка не обрезается
//  молча. Чтение, оборвавшееся раньше конца, — `audioUnreadable(path:)` (C-011 v7, инв. 17);
//  невыделенный буфер блока — `runtimeFailure`; ни то, ни другое конвертер не принимает за
//  конец потока. Плюс зафиксированное поведение на файле без единого кадра (вопрос IR-154).

import AVFoundation
import XCTest
import EngineKit
@testable import EngineXPCService

final class AudioTrackReaderTruncationTests: AudioTrackReaderTestCase {

    // MARK: - Обрыв чтения посреди файла (инв. 17)

    /// Честный `data`-чанк на 2 с, а байт в файле — на 1 с: `AVAudioFile.length` берётся из
    /// заголовка, чтение за первой секундой не отдаёт кадров. Раньше это был молчаливый конец
    /// потока (дорожка в 1 с без ошибки), теперь — `audioUnreadable` с путём из `fileURL`.
    func testReadBreakingOffMidFileIsAudioUnreadable() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 2_000, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )
        try truncate(url, droppingTrailingBytes: 48_000 * 2 * 4)
        let ref = try audioRef(url, channelCount: 2)

        assertAudioUnreadable({ try AudioTrackReader.read(ref) }, path: url.path)
        assertAudioUnreadable(
            { try AudioTrackReader.read(AudioSlice(source: ref, startMs: 500, endMs: 1_500)) }, path: url.path
        )
    }

    /// Пустое чтение раньше `length` (`frameLength == 0`) — обрыв, а не конец потока: раньше
    /// `next()` отдавал `nil`, и конвертер молча обрезал дорожку. Синтетикой не воспроизводится
    /// (на обрезанном CAF Core Audio бросает — вектор выше), поэтому чтение подменено пустым.
    func testEmptyReadBeforeEndOfFileIsAudioUnreadable() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 500, hz: 440, amplitudes: [1])],
            sampleRate: 48_000, channels: 1, to: directory
        )
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = BlockSource(file: file, remaining: nil, path: url.path, readBlock: { _, _, _ in })

        XCTAssertThrowsError(try source.next()) { error in
            XCTAssertEqual(error as? EngineError, .audioUnreadable(path: url.path))
        }
    }

    /// Сквозной вектор пустого чтения (MEE-488, п. 9): через `read(AudioRef)` и `read(AudioSlice)`,
    /// а не через `BlockSource` напрямую. Первый блок читается настоящим файлом, второй — пусто
    /// до конца вырезки: итог — `audioUnreadable` с путём из `fileURL`, не укороченная дорожка.
    func testEmptyReadMidTrackThroughReadIsAudioUnreadable() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 3_000, hz: 440, amplitudes: [1])],
            sampleRate: 48_000, channels: 1, to: directory
        )
        let ref = try audioRef(url, channelCount: 1, channel: .mic)
        func emptyAfterFirstBlock() -> (BlockSource.BlockReader, CallCounter) {
            let calls = CallCounter()
            let reader: BlockSource.BlockReader = { file, buffer, frames in
                if calls.increment() == 1 { try BlockSource.fileReader(file, buffer, frames) }
            }
            return (reader, calls)
        }

        let (wholeReader, wholeCalls) = emptyAfterFirstBlock()
        assertAudioUnreadable(
            { try AudioTrackReader.read(ref, allocate: AudioTrackReader.systemAllocator, readBlock: wholeReader) },
            path: url.path
        )
        XCTAssertEqual(wholeCalls.value, 2, "отказ — на втором, пустом блоке")

        let (sliceReader, sliceCalls) = emptyAfterFirstBlock()
        assertAudioUnreadable(
            { try AudioTrackReader.read(AudioSlice(source: ref, startMs: 500, endMs: 2_500), readBlock: sliceReader) },
            path: url.path
        )
        XCTAssertEqual(sliceCalls.value, 2, "отказ — на втором, пустом блоке")
    }

    /// Конец файла — по-прежнему `nil`, не отказ: после чтения всех кадров источник пуст.
    func testBlockSourceEndsWithNilAtEndOfFile() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 500, hz: 440, amplitudes: [1])],
            sampleRate: 48_000, channels: 1, to: directory
        )
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let source = BlockSource(file: file, remaining: nil, path: url.path)

        // Core Audio вправе отдать блок короче запрошенного — считаем кадры до `nil`.
        var total: AVAudioFrameCount = 0
        while let block = try source.next() { total += block.frameLength }
        XCTAssertEqual(total, 24_000)
        XCTAssertNil(try source.next())
    }

    /// Та же обрезанная дорожка, но вырезка целиком в уцелевшей части — читается без отказа:
    /// отказ привязан к обрыву, а не к файлу вообще.
    func testSliceInsideSurvivingPartOfBrokenFileIsRead() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 2_000, hz: 440, amplitudes: [1, 1])],
            sampleRate: 48_000, channels: 2, to: directory
        )
        try truncate(url, droppingTrailingBytes: 48_000 * 2 * 4)
        let ref = try audioRef(url, channelCount: 2)

        let samples = try AudioTrackReader.read(AudioSlice(source: ref, startMs: 0, endMs: 500))

        XCTAssertEqual(Double(samples.count), 8_000, accuracy: 1)
    }

    // MARK: - Невыделенный буфер блока — `runtimeFailure`, не конец потока

    func testBlockBufferAllocationFailureIsRuntimeFailure() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 500, hz: 440, amplitudes: [1])],
            sampleRate: 48_000, channels: 1, to: directory
        )
        let ref = try audioRef(url, channelCount: 1, channel: .mic)

        XCTAssertThrowsError(try AudioTrackReader.read(ref, allocate: { _, _ in nil })) { error in
            guard case EngineError.runtimeFailure(let message) = error else {
                return XCTFail("ожидался EngineError.runtimeFailure, получено \(error)")
            }
            XCTAssertTrue(message.contains(url.path), message)
        }
    }

    /// Отказ выделения посреди дорожки (второй блок): дорожка не обрезается по первому блоку.
    func testBlockBufferAllocationFailureAfterFirstBlockIsRuntimeFailure() throws {
        let url = try SyntheticCAF.write(
            [SyntheticCAF.tone(ms: 3_000, hz: 440, amplitudes: [1])],
            sampleRate: 48_000, channels: 1, to: directory
        )
        let ref = try audioRef(url, channelCount: 1, channel: .mic)
        let calls = CallCounter()
        let failingSecond: AudioTrackReader.BufferAllocator = { format, capacity in
            calls.increment() == 1 ? AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) : nil
        }

        XCTAssertThrowsError(try AudioTrackReader.read(ref, allocate: failingSecond)) { error in
            guard case EngineError.runtimeFailure = error else {
                return XCTFail("ожидался EngineError.runtimeFailure, получено \(error)")
            }
        }
        XCTAssertEqual(calls.value, 2)
    }

    // MARK: - Файл без единого кадра (C-011 v8 инв. 17, IR-154)

    /// Заголовок разобран и совпал, `data` пуст: по инв. 17 («Файл без кадров») `read(AudioRef)` —
    /// `[]` без ошибки, длительность — 0 мс (по ней движок пропускает канал, MEE-509); вырезка —
    /// `unsupportedRequest` (инв. 16).
    func testZeroFrameFileReadsAsEmptyTrack() throws {
        let url = try SyntheticCAF.write([], sampleRate: 48_000, channels: 1, to: directory)
        let ref = try audioRef(url, channelCount: 1, channel: .mic)

        XCTAssertEqual(try AudioTrackReader.read(ref), [])
        XCTAssertEqual(try AudioTrackReader.durationMs(of: ref), 0)
        assertUnsupportedRequest { try AudioTrackReader.read(AudioSlice(source: ref, startMs: 0, endMs: 100)) }
    }

    private func truncate(_ url: URL, droppingTrailingBytes count: Int) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(size - count))
        try handle.close()
    }
}

/// Счётчик вызовов для `@Sendable` подмен (MEE-488, п. 7): захват изменяемой `var` в
/// `@Sendable`-замыкании — ошибка компиляции.
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    /// Номер этого вызова, с 1.
    @discardableResult
    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}
