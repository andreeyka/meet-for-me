import AVFoundation
import CoreAudio
import Foundation

/// Опорный сигнал для R2 и источник «чужой речи» для R1/R6. Отдельный процесс, который tap слушает как клиента созвона.
/// Пишет прямо в IO-процедуру конкретного устройства вывода (по UID): при подключении AirPods щелчки
/// остаются на встроенных динамиках, и микрофон продолжает их слышать.
enum ReferenceSignal {
    static let chirpSeconds = 0.02

    /// Линейный чирп, окно Ханна. Один и тот же шаблон генерирует плеер и ищет анализ.
    /// low — 800→6000 Гц (слышно); high — 17 500→20 500 Гц (практически не слышно, для часовой записи рядом с человеком).
    static func chirp(rate: Double, band: String = "low") -> [Float] {
        let count = Int(chirpSeconds * rate)
        let (f0, f1) = band == "high" ? (17_500.0, 20_500.0) : (800.0, 6000.0)
        return (0..<count).map { index in
            let t = Double(index) / rate
            let phase = 2 * Double.pi * (f0 * t + (f1 - f0) * t * t / (2 * chirpSeconds))
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(count - 1))
            return Float(sin(phase) * window)
        }
    }
}

final class Player {
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    /// `schedule` — моменты старта файла в секундах от запуска плеера (один процесс — один PID для tap).
    func run(deviceUID: String?, period: Double, amplitude: Float, band: String, file: URL?, schedule: [Double],
             seconds: Double?) throws -> Never {
        guard let device = deviceUID.flatMap(HAL.device(uid:)) ?? HAL.defaultOutput() else {
            throw HALError(status: -1, what: "устройство вывода не найдено")
        }
        deviceID = device
        let rate = HAL.nominalRate(device)
        let outputChannels = HAL.streamChannels(device, scope: kAudioObjectPropertyScopeOutput)
        let chirp = ReferenceSignal.chirp(rate: rate, band: band).map { $0 * amplitude }
        var speech: [Float] = []
        if let file { speech = try Self.loadMono(file, rate: rate).map { $0 * amplitude } }

        let periodFrames = Int((period * rate).rounded())
        let delayFrames = Int(((schedule.first ?? 0.5) * rate).rounded())
        let starts = schedule.map { Int(($0 * rate).rounded()) }
        var position = 0

        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, output, _ in
            let list = UnsafeMutableAudioBufferListPointer(output)
            guard let first = list.first else { return }
            let channels = max(1, Int(first.mNumberChannels))
            let frames = Int(first.mDataByteSize) / 4 / channels
            for frame in 0..<frames {
                let absolute = position + frame
                var sample: Float = 0
                if file == nil {
                    let local = absolute - delayFrames
                    if local >= 0 {
                        let inPeriod = local % periodFrames
                        if inPeriod < chirp.count { sample = chirp[inPeriod] }
                    }
                } else {
                    for start in starts where absolute >= start && absolute - start < speech.count {
                        sample += speech[absolute - start]
                    }
                }
                for buffer in list {
                    guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let bufferChannels = max(1, Int(buffer.mNumberChannels))
                    for channel in 0..<bufferChannels { data[frame * bufferChannels + channel] = sample }
                }
            }
            position += frames
        }, "AudioDeviceCreateIOProcIDWithBlock(output)")
        try check(AudioDeviceStart(device, procID), "AudioDeviceStart(output)")
        let info: [String: Any] = ["pid": getpid(), "device": HAL.describeDevice(device), "rate": rate,
                                   "outputChannels": outputChannels, "periodS": period, "band": band, "file": file?.path ?? "-",
                                   "schedule": schedule,
                                   "speechSeconds": Double(speech.count) / rate, "startHostS": hostTimeSeconds(nowHost())]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys, .withoutEscapingSlashes]) {
            print(String(decoding: data, as: UTF8.self))
        }
        setvbuf(stdout, nil, _IONBF, 0)

        var limit = seconds
        if limit == nil, file != nil { limit = (schedule.max() ?? 0) + Double(speech.count) / rate + 1 }
        if let limit {
            DispatchQueue.main.asyncAfter(deadline: .now() + limit) { [self] in
                AudioDeviceStop(deviceID, procID)
                exit(0)
            }
        }
        signal(SIGINT) { _ in exit(0) }
        RunLoop.main.run()
        exit(0)
    }

    static func loadMono(_ url: URL, rate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: input)
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(Double(input.frameLength) * rate / source.sampleRate) + 1024)
        else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
