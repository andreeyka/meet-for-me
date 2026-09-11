import AVFoundation
import Accelerate
import CoreAudio
import Foundation
import os

final class UnfairLock {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>
    init() {
        pointer = .allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }
    deinit { pointer.deallocate() }
    @inline(__always) func lock() { os_unfair_lock_lock(pointer) }
    @inline(__always) func unlock() { os_unfair_lock_unlock(pointer) }
}

/// Кольцевой буфер Float32 interleaved с предвыделенной памятью. Пишет IO-поток, читает поток записи.
/// Критическая секция — memcpy под os_unfair_lock; аллокаций в IO-потоке нет.
final class RingBuffer {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var writeIndex = 0
    private var count = 0
    private var channels = 1
    private var droppedSamples = 0
    private let lock = UnfairLock()

    init(seconds: Double, rate: Double, maxChannels: Int = 8) {
        capacity = Int(seconds * max(rate, 48000)) * maxChannels
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    func reset(channels: Int) {
        lock.lock(); defer { lock.unlock() }
        self.channels = max(1, channels)
        readIndex = 0; writeIndex = 0; count = 0
    }

    func write(_ source: UnsafePointer<Float>, samples: Int) {
        lock.lock(); defer { lock.unlock() }
        let free = ((capacity - count) / channels) * channels
        let toWrite = min((samples / channels) * channels, free)
        droppedSamples += samples - toWrite
        let first = min(toWrite, capacity - writeIndex)
        (storage + writeIndex).update(from: source, count: first)
        if toWrite > first { storage.update(from: source + first, count: toWrite - first) }
        writeIndex = (writeIndex + toWrite) % capacity
        count += toWrite
    }

    /// Читает только целые кадры: `maxSamples` должен быть кратен числу каналов.
    func read(into destination: UnsafeMutablePointer<Float>, maxSamples: Int) -> Int {
        lock.lock(); defer { lock.unlock() }
        let toRead = min((maxSamples / channels) * channels, count)
        let first = min(toRead, capacity - readIndex)
        destination.update(from: storage + readIndex, count: first)
        if toRead > first { (destination + first).update(from: storage, count: toRead - first) }
        readIndex = (readIndex + toRead) % capacity
        count -= toRead
        return toRead
    }

    var dropped: Int { lock.lock(); defer { lock.unlock() }; return droppedSamples }
}

enum TrackKind: String, CaseIterable {
    case mic, system, systemNoDrift, rest, micVP

    var fileName: String {
        switch self {
        case .mic: return "audio-mic.caf"
        case .system: return "audio-system.caf"
        case .systemNoDrift: return "diag-system-nodrift.caf"
        case .rest: return "diag-rest.caf"
        case .micVP: return "diag-mic-vp.caf"
        }
    }
}

/// Трек на диске: формат файла фиксирован первой сессией; формат текущей сессии может отличаться
/// (другой микрофон после пересборки) — тогда каналы подгоняются, частота пересчитывается AVAudioConverter.
final class Track {
    let kind: TrackKind
    let rate: Double
    let channels: Int
    let ring: RingBuffer
    let sink: AudioSink
    private(set) var framesWritten: Int64 = 0
    private(set) var sessionRate: Double
    private(set) var sessionChannels: Int
    var awaitingAlignment = false

    private var converter: AVAudioConverter?
    private let scratchSamples = 48000 * 8
    private let scratch: UnsafeMutablePointer<Float>
    private let adapted: UnsafeMutablePointer<Float>

    init(kind: TrackKind, directory: URL, rate: Double, channels: Int, writer: String) throws {
        self.kind = kind
        self.rate = rate
        self.channels = channels
        sessionRate = rate
        sessionChannels = channels
        ring = RingBuffer(seconds: 20, rate: rate)
        ring.reset(channels: channels)
        let url = directory.appendingPathComponent(kind.fileName)
        sink = writer == "apple"
            ? try ExtAudioFileSink(url: url, sampleRate: rate, channels: channels)
            : try RawCAFSink(url: url, sampleRate: rate, channels: channels)
        scratch = .allocate(capacity: scratchSamples)
        adapted = .allocate(capacity: scratchSamples)
    }

    func configureSession(rate newRate: Double, channels newChannels: Int) {
        sessionRate = newRate
        sessionChannels = max(1, newChannels)
        ring.reset(channels: sessionChannels)
        converter = nil
        if newRate != rate,
           let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: newRate,
                                    channels: AVAudioChannelCount(channels), interleaved: true),
           let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                  channels: AVAudioChannelCount(channels), interleaved: true) {
            converter = AVAudioConverter(from: from, to: to)
        }
    }

    func drain() throws {
        guard !awaitingAlignment else { return }
        while true {
            let samples = ring.read(into: scratch, maxSamples: (scratchSamples / sessionChannels) * sessionChannels)
            if samples == 0 { return }
            try writeSessionFrames(samples / sessionChannels)
            if samples < scratchSamples / 2 { return }
        }
    }

    func writeSilence(frames: Int64) throws {
        var remaining = frames
        let chunk = Int64(scratchSamples / channels)
        adapted.update(repeating: 0, count: scratchSamples)
        while remaining > 0 {
            let now = Int(min(remaining, chunk))
            try sink.write(adapted, frames: now)
            framesWritten += Int64(now)
            remaining -= Int64(now)
        }
    }

    private func writeSessionFrames(_ frames: Int) throws {
        var source = UnsafePointer(scratch)
        if sessionChannels != channels {
            for frame in 0..<frames {
                for channel in 0..<channels {
                    adapted[frame * channels + channel] = scratch[frame * sessionChannels + min(channel, sessionChannels - 1)]
                }
            }
            source = UnsafePointer(adapted)
        }
        guard let converter else {
            try sink.write(source, frames: frames)
            framesWritten += Int64(frames)
            return
        }
        guard let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(frames)),
              let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat,
                                            frameCapacity: AVAudioFrameCount(Double(frames) * rate / sessionRate) + 256)
        else { return }
        input.frameLength = AVAudioFrameCount(frames)
        input.audioBufferList.pointee.mBuffers.mData!.copyMemory(from: source, byteCount: frames * channels * 4)
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        let converted = output.audioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        try sink.write(converted, frames: Int(output.frameLength))
        framesWritten += Int64(output.frameLength)
    }
}

/// Состояние, которое трогает IO-поток aggregate device. Статистика — под замком, чтение снимком.
final class IOContext {
    struct Route {
        let bufferIndex: Int
        let ring: RingBuffer
        let channels: Int
    }

    struct Snapshot {
        var callbacks = 0
        var frames: Int64 = 0
        var firstHost: UInt64 = 0
        var lastHost: UInt64 = 0
        var lastFrameCount: UInt32 = 0
        var sampleTimeJumps = 0
        var jumpedFrames: Double = 0
        var channelMismatches = 0
        var observedChannels: [Int] = []
        var peaks: [Float] = []
    }

    let routes: [Route]
    private let lock = UnfairLock()
    private var state = Snapshot()
    private var lastSampleTime: Double = -1
    private let peaks: UnsafeMutablePointer<Float>

    private let observed: UnsafeMutablePointer<Int>
    private var mismatches = 0

    init(routes: [Route]) {
        self.routes = routes
        peaks = .allocate(capacity: max(1, routes.count))
        peaks.initialize(repeating: 0, count: max(1, routes.count))
        observed = .allocate(capacity: max(1, routes.count))
        observed.initialize(repeating: 0, count: max(1, routes.count))
    }

    deinit {
        peaks.deallocate()
        observed.deallocate()
    }

    func handle(_ input: UnsafePointer<AudioBufferList>, _ time: UnsafePointer<AudioTimeStamp>) {
        let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        var frameCount: UInt32 = 0
        for (index, route) in routes.enumerated() where route.bufferIndex < list.count {
            let buffer = list[route.bufferIndex]
            guard let data = buffer.mData else { continue }
            let samples = Int(buffer.mDataByteSize) / 4
            let pointer = data.assumingMemoryBound(to: Float.self)
            observed[index] = Int(buffer.mNumberChannels)
            frameCount = UInt32(samples / max(1, Int(buffer.mNumberChannels)))
            // Формат потока сменился под aggregate device (например, другой клиент включил voice processing):
            // такой буфер в трек не пишем — иначе файл молча портится. Пересборку запускает слушатель конфигурации.
            if Int(buffer.mNumberChannels) != route.channels {
                mismatches += 1
                continue
            }
            route.ring.write(pointer, samples: samples)
            var peak: Float = 0
            vDSP_maxmgv(pointer, 1, &peak, vDSP_Length(samples))
            if peak > peaks[index] { peaks[index] = peak }
        }
        let timestamp = time.pointee
        lock.lock()
        if state.firstHost == 0 { state.firstHost = timestamp.mHostTime }
        if lastSampleTime >= 0 {
            let expected = lastSampleTime + Double(state.lastFrameCount)
            if abs(timestamp.mSampleTime - expected) > 0.5 {
                state.sampleTimeJumps += 1
                state.jumpedFrames += timestamp.mSampleTime - expected
            }
        }
        lastSampleTime = timestamp.mSampleTime
        state.lastHost = timestamp.mHostTime
        state.lastFrameCount = frameCount
        state.callbacks += 1
        state.frames += Int64(frameCount)
        lock.unlock()
    }

    func snapshot(resetPeaks: Bool = false) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        var copy = state
        copy.peaks = (0..<routes.count).map { peaks[$0] }
        copy.observedChannels = (0..<routes.count).map { observed[$0] }
        copy.channelMismatches = mismatches
        if resetPeaks { for index in 0..<routes.count { peaks[index] = 0 } }
        return copy
    }
}

func dBFS(_ value: Float) -> Double { value > 0 ? 20 * log10(Double(value)) : -200 }
