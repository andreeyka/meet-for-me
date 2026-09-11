import AudioToolbox
import Foundation

/// Приёмник PCM Float32 interleaved одного трека.
protocol AudioSink: AnyObject {
    func write(_ samples: UnsafePointer<Float>, frames: Int) throws
    func sync()
    func close()
}

/// Свой CAF: заголовок `data` с размером -1 («до конца файла», допускается спецификацией CAF, если `data` —
/// последний чанк). Данные дописываются в конец; при корректном закрытии размер проставляется честно.
/// После kill -9 файл остаётся валидным CAF неизвестной длины.
final class RawCAFSink: AudioSink {
    private let fd: Int32
    private let channels: Int
    private var dataBytes: Int64 = 0
    private var dataSizeOffset: off_t = 0

    init(url: URL, sampleRate: Double, channels: Int) throws {
        self.channels = channels
        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

        var header = Data()
        header.appendASCII("caff"); header.appendBE(UInt16(1)); header.appendBE(UInt16(0))
        header.appendASCII("desc"); header.appendBE(Int64(32))
        header.appendBE(sampleRate.bitPattern)
        header.appendASCII("lpcm")
        header.appendBE(UInt32(1 | 2))              // kCAFLinearPCMFormatFlagIsFloat | IsLittleEndian
        header.appendBE(UInt32(4 * channels))       // mBytesPerPacket
        header.appendBE(UInt32(1))                  // mFramesPerPacket
        header.appendBE(UInt32(channels))
        header.appendBE(UInt32(32))
        header.appendASCII("data")
        dataSizeOffset = off_t(header.count)
        header.appendBE(Int64(-1))
        header.appendBE(UInt32(0))                  // mEditCount
        try writeAll(header)
    }

    func write(_ samples: UnsafePointer<Float>, frames: Int) throws {
        let bytes = frames * channels * 4
        var offset = 0
        while offset < bytes {
            let written = Darwin.write(fd, UnsafeRawPointer(samples) + offset, bytes - offset)
            guard written > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            offset += written
        }
        dataBytes += Int64(bytes)
    }

    func sync() { fsync(fd) }

    func close() {
        var size = (dataBytes + 4).bigEndian
        _ = withUnsafeBytes(of: &size) { pwrite(fd, $0.baseAddress, 8, dataSizeOffset) }
        fsync(fd)
        Darwin.close(fd)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard Darwin.write(fd, raw.baseAddress, raw.count) == raw.count else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
        }
    }
}

/// CAF через ExtAudioFile — то, что продукт получил бы от AVAudioFile. Нужен для сравнения в R9.
final class ExtAudioFileSink: AudioSink {
    private var file: ExtAudioFileRef?
    private let channels: Int

    init(url: URL, sampleRate: Double, channels: Int) throws {
        self.channels = channels
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        try check(ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &format, nil,
                                            AudioFileFlags.eraseFile.rawValue, &file), "ExtAudioFileCreateWithURL")
    }

    func write(_ samples: UnsafePointer<Float>, frames: Int) throws {
        guard let file else { return }
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: UInt32(channels), mDataByteSize: UInt32(frames * channels * 4),
            mData: UnsafeMutableRawPointer(mutating: samples)))
        try check(ExtAudioFileWrite(file, UInt32(frames), &list), "ExtAudioFileWrite")
    }

    func sync() {}

    func close() {
        if let file { ExtAudioFileDispose(file) }
        file = nil
    }
}

extension Data {
    mutating func appendASCII(_ string: String) { append(contentsOf: Array(string.utf8)) }
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

/// Разбор CAF-заголовка без Core Audio: чтобы после крэша увидеть, что реально лежит на диске.
struct CAFInspection {
    var sampleRate: Double = 0
    var channels = 0
    var bytesPerFrame = 0
    var formatID = ""
    var dataOffset: Int64 = 0
    var declaredDataSize: Int64 = 0   // -1 — «до конца файла»
    var fileSize: Int64 = 0
    var chunks: [String] = []

    var framesOnDisk: Int64 { bytesPerFrame > 0 ? max(0, fileSize - dataOffset) / Int64(bytesPerFrame) : 0 }
    var trailingBytes: Int64 { bytesPerFrame > 0 ? max(0, fileSize - dataOffset) % Int64(bytesPerFrame) : 0 }

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        fileSize = Int64(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let head = handle.readData(ofLength: 8)
        guard head.count == 8, String(bytes: head.prefix(4), encoding: .ascii) == "caff" else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var offset: UInt64 = 8
        while offset + 12 <= UInt64(fileSize) {
            try handle.seek(toOffset: offset)
            let chunkHeader = handle.readData(ofLength: 12)
            let type = String(bytes: chunkHeader.prefix(4), encoding: .ascii) ?? "????"
            let size = chunkHeader.suffix(8).reduce(Int64(0)) { ($0 << 8) | Int64($1) }
            chunks.append("\(type):\(size)")
            if type == "desc" {
                let body = handle.readData(ofLength: 32)
                let bytes = [UInt8](body)
                func be32(_ at: Int) -> UInt32 { bytes[at..<at + 4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } }
                sampleRate = Double(bitPattern: bytes[0..<8].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) })
                formatID = fourCC(be32(8))
                bytesPerFrame = Int(be32(16))
                channels = Int(be32(24))
            }
            if type == "data" {
                declaredDataSize = size
                dataOffset = Int64(offset) + 12 + 4
                break
            }
            guard size >= 0 else { break }
            offset += 12 + UInt64(size)
        }
    }
}
