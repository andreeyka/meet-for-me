//  TrackFile — трек на диске: заголовок CAF, дозапись PCM Float32, синхронный fsync.
//
//  Модуль: capture · Владелец: DEV-1 · Слой: адаптер системного API
//
//  Формат — по контракту (раздел «Определение», `Track.format`): всегда `pcm-caf`, не `aac-m4a`.
//  Финализация в AAC — вне этого модуля (спайк MEE-8, «Упрощения спайка»: «Финализации в AAC
//  нет: манифест остаётся pcm-caf»; этот модуль зеркалит то же решение, а не открывает его заново).
//
//  Заголовок — `data`-чанк заявленной длины -1 («до конца файла», допускается спецификацией CAF
//  для последнего чанка): после `SIGKILL` файл остаётся ЧИТАЕМЫМ CAF неизвестной длины, а не
//  повреждённым — это несущее свойство для К27(б) и для `recover`. При штатном закрытии длина
//  дописывается честно.
//
//  `package`, не `public`: точка входа записи трека для харнесса-писателя (К27б, план MEE-315
//  §6) и без единого лишнего публичного типа модуля (инвариант 25 — разрешённый список C-004
//  этот тип не называет).

import DomainCore
import Foundation

enum TrackFileError: Error {
    case cannotOpen(path: String, errno: Int32)
    case writeFailed(errno: Int32)
}

/// Один трек: заголовок пишется в `init`, дальше только дозапись и периодический `flush()`.
package final class TrackFile: @unchecked Sendable {

    let channel: RecordingManifest.Channel
    package let fileName: String
    let sampleRate: Int
    let channelCount: Int

    private let lock = NSLock()
    private let fd: Int32
    private var dataBytes: Int64 = 0
    private let dataSizeOffset: off_t
    private var lastFlushHostTime: UInt64 = 0

    /// Кадров, реально дошедших до диска. Источник шкалы `atMs` для маркеров и разрывов —
    /// позиция в опорном треке, а не часы (контракт, «Поведение», «Шкала»).
    var framesWritten: Int64 {
        lock.lock(); defer { lock.unlock() }
        return dataBytes / Int64(channelCount * 4)
    }

    var positionMs: Int {
        Int((Double(framesWritten) / Double(sampleRate) * 1000).rounded())
    }

    package init(directory: URL, channel: RecordingManifest.Channel, format: TrackFormat) throws {
        self.channel = channel
        fileName = TrackFile.fileName(for: channel)
        sampleRate = format.sampleRate
        channelCount = format.channelCount
        let path = directory.appendingPathComponent(fileName).path
        let opened = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard opened >= 0 else { throw TrackFileError.cannotOpen(path: path, errno: errno) }
        fd = opened

        var header = Data()
        header.appendASCII("caff")
        header.appendBE(UInt16(1))
        header.appendBE(UInt16(0))
        header.appendASCII("desc")
        header.appendBE(Int64(32))
        header.appendBE(Double(sampleRate).bitPattern)
        header.appendASCII("lpcm")
        header.appendBE(UInt32(0x1 | 0x2))              // Float | LittleEndian
        header.appendBE(UInt32(4 * channelCount))       // mBytesPerPacket
        header.appendBE(UInt32(1))                       // mFramesPerPacket
        header.appendBE(UInt32(channelCount))
        header.appendBE(UInt32(32))
        header.appendASCII("data")
        dataSizeOffset = off_t(header.count)
        header.appendBE(Int64(-1))
        header.appendBE(UInt32(0))                       // mEditCount
        do {
            try TrackFile.writeAll(header, to: fd)
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    static func fileName(for channel: RecordingManifest.Channel) -> String {
        switch channel {
        case .mic: return "audio-mic.caf"
        case .system: return "audio-system.caf"
        }
    }

    /// Байт заголовка до начала `data` — сумма констант `init` выше (`caff`+`desc`+тело `desc`
    /// (32)+`data`+8 байт размера+4 байта `mEditCount`): 8+12+32+4+8+4 = 68. `recover` читает им
    /// длину, реально дошедшую до диска, без Core Audio (тот же приём, что у `CAFInspection`
    /// спайка — разбор заголовка вручную, чтобы видеть файл после `SIGKILL` таким, какой он есть).
    static let headerByteCount = 68

    /// Кадров, реально записанных на диск, по фактическому размеру файла — не по внутреннему
    /// счётчику процесса, которого после аварийного завершения уже нет.
    static func framesOnDisk(at url: URL, channelCount: Int) -> Int64 {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64,
              size > Int64(headerByteCount) else { return 0 }
        let bytesPerFrame = Int64(channelCount * 4)
        guard bytesPerFrame > 0 else { return 0 }
        return (size - Int64(headerByteCount)) / bytesPerFrame
    }

    /// Дописывает interleaved Float32. Байты идут на диск сразу — накопление и частоту сброса
    /// решает вызывающая сторона (`flush()` ниже), эта функция сама не буферизует.
    package func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        try samples.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            try base.withMemoryRebound(to: UInt8.self, capacity: buffer.count * 4) { bytes in
                try TrackFile.writeAll(bytes: bytes, count: buffer.count * 4, to: fd)
            }
        }
        lock.lock()
        dataBytes += Int64(samples.count * 4)
        lock.unlock()
    }

    /// Сбрасывает на диск (инвариант 26: не реже `truncatedTailBudgetMs`, пока идут данные).
    package func flush(atHostTime hostTime: UInt64) {
        lock.lock()
        lastFlushHostTime = hostTime
        lock.unlock()
        fsync(fd)
    }

    var lastFlushAt: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return lastFlushHostTime
    }

    /// Штатное закрытие: заявленная длина `data` дописывается честно (не -1).
    func finalize() {
        lock.lock()
        var size = (dataBytes + 4).bigEndian
        lock.unlock()
        _ = withUnsafeBytes(of: &size) { pwrite(fd, $0.baseAddress, 8, dataSizeOffset) }
        fsync(fd)
        Darwin.close(fd)
    }

    private static func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            try writeAll(bytes: base.assumingMemoryBound(to: UInt8.self), count: raw.count, to: fd)
        }
    }

    private static func writeAll(bytes: UnsafePointer<UInt8>, count: Int, to fd: Int32) throws {
        var offset = 0
        while offset < count {
            let written = Darwin.write(fd, bytes + offset, count - offset)
            guard written > 0 else { throw TrackFileError.writeFailed(errno: errno) }
            offset += written
        }
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) { append(contentsOf: Array(string.utf8)) }
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
