//  AudioTrackReader — чтение дорожки записи по `AudioRef` (C-011 §1) в вход ASR: 16 000 Гц,
//  моно, Float32. Захват пишет `pcm-caf` 48 кГц (системная дорожка — стерео, микрофон — моно,
//  `Capture/TrackFile.swift`), GigaAM v3 принимает 16 кГц моно (спайк R12, MEE-426); звено
//  между ними не зависит ни от модели, ни от среды выполнения (MEE-475).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок (сторона сервиса)
//
//  ПОЧЕМУ ЗДЕСЬ, А НЕ В `GigaAM`. `Packages/Core` собирается и тестируется вне macOS,
//  `AVFoundation` там недоступен. Будущий движок получит чтение внедрённой функцией из точки
//  входа сервиса (`Services/TranscriptionEngineXPC/Sources/main.swift`) — тем же приёмом, что
//  `EngineBundle`. Публичная сигнатура несёт только `AudioRef`/`AudioSlice` (`EngineKit`) и
//  `[Float]`: ни один тип `AVFoundation` наружу не выходит (барьер символьного графа —
//  заголовок `EngineXPCRequestHandler.swift`).
//
//  ШКАЛА (MEE-475, «Предмет»; шапка `EngineAudio.swift`). Образцы файла до `offsetMs` не
//  отдаются; отрезок `AudioSlice` отсчитывается по шкале дорожки ПОСЛЕ `offsetMs`: кадр
//  `startMs` вырезки — это кадр `offsetMs + startMs` файла. Части вырезки за концом файла нет —
//  она не дополняется нулями; пустая или обратная вырезка (`endMs <= startMs`) даёт `[]`.
//
//  ПОТОКОВО. Файл читается блоками по `blockFrames` кадров исходной частоты; каждый блок сразу
//  уходит в `AVAudioConverter` (передискретизация и сведение в моно, `downmix = true` — среднее
//  каналов, проверено тестом на стерео с разной громкостью каналов). В памяти целиком — только
//  итог 16 кГц моно: около 230 МБ Float32 на час.
//
//  CAF С ДЛИНОЙ −1 (К27(б) C-004: запись оборвана `SIGKILL`). `data`-чанк заявленной длины −1
//  по спецификации CAF тянется до конца файла; Core Audio так его и читает. Цикл чтения
//  останавливается на пустом блоке, а не на `AVAudioFile.length`, так что длина из заголовка
//  на результат не влияет.
//
//  ОТКАЗЫ — `EngineError` (C-011), без нового случая (MEE-475): файла нет, не открывается или
//  не читается — `.runtimeFailure(message:)` с путём; `sampleRate`/`channelCount` в `AudioRef`
//  не совпадают с заголовком файла — то же, с обоими значениями.

import AVFoundation
import EngineKit
import Foundation

public enum AudioTrackReader {

    /// Частота результата — вход ASR (GigaAM v3, спайк R12).
    public static let outputSampleRate = 16_000

    /// Кадров исходной частоты на блок чтения: секунда при 48 кГц.
    static let blockFrames: AVAudioFrameCount = 48_000

    /// Вся дорожка после `offsetMs`.
    public static func read(_ ref: AudioRef) throws -> [Float] {
        try read(ref, startMs: 0, endMs: nil)
    }

    /// Вырезка `startMs..<endMs` на шкале дорожки после `offsetMs`.
    public static func read(_ slice: AudioSlice) throws -> [Float] {
        guard slice.endMs > slice.startMs else { return [] }
        return try read(slice.source, startMs: max(0, slice.startMs), endMs: slice.endMs)
    }

    // MARK: - Реализация

    private static func read(_ ref: AudioRef, startMs: Int, endMs: Int?) throws -> [Float] {
        let file = try open(ref)
        let sourceRate = file.fileFormat.sampleRate
        let firstFrame = frames(ms: max(0, ref.offsetMs) + startMs, rate: sourceRate)
        let lastFrame = endMs.map { frames(ms: max(0, ref.offsetMs) + $0, rate: sourceRate) }

        // За концом файла читать нечего. `length` у CAF с длиной −1 Core Audio выводит из
        // размера файла; если он окажется меньше, цикл ниже всё равно дочитает до пустого блока.
        if file.length > 0, firstFrame >= file.length { return [] }
        file.framePosition = firstFrame

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(outputSampleRate),
            channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw EngineError.runtimeFailure(
                message: "нет преобразования \(file.processingFormat) → 16000 Гц моно: \(ref.fileURL.path)"
            )
        }
        converter.downmix = true

        let source = BlockSource(file: file, remaining: lastFrame.map { max(0, $0 - firstFrame) })
        return try convert(from: source, with: converter, into: target, path: ref.fileURL.path)
    }

    private static func open(_ ref: AudioRef) throws -> AVAudioFile {
        let path = ref.fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw EngineError.runtimeFailure(message: "дорожка не найдена: \(path)")
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: ref.fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw EngineError.runtimeFailure(message: "дорожка не читается: \(path): \(error.localizedDescription)")
        }
        let header = file.fileFormat
        if Double(ref.sampleRate) != header.sampleRate || ref.channelCount != Int(header.channelCount) {
            throw EngineError.runtimeFailure(message: """
                заголовок дорожки не совпадает с AudioRef: \(path): \
                sampleRate AudioRef \(ref.sampleRate), файл \(Int(header.sampleRate)); \
                channelCount AudioRef \(ref.channelCount), файл \(header.channelCount)
                """)
        }
        return file
    }

    private static func frames(ms: Int, rate: Double) -> AVAudioFramePosition {
        AVAudioFramePosition((Double(ms) * rate / 1000).rounded())
    }

    private static func convert(
        from source: BlockSource, with converter: AVAudioConverter,
        into target: AVAudioFormat, path: String
    ) throws -> [Float] {
        let ratio = target.sampleRate / source.file.processingFormat.sampleRate
        let outCapacity = AVAudioFrameCount((Double(blockFrames) * ratio).rounded(.up)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCapacity) else {
            throw EngineError.runtimeFailure(message: "не выделен буфер вывода: \(path)")
        }
        var samples: [Float] = []
        if let expected = source.expectedFrames {
            samples.reserveCapacity(Int((Double(expected) * ratio).rounded(.up)) + 1)
        }
        var readError: Error?
        while true {
            out.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: out, error: &conversionError) { _, inputStatus in
                do {
                    if let block = try source.next() {
                        inputStatus.pointee = .haveData
                        return block
                    }
                } catch {
                    readError = error
                }
                inputStatus.pointee = .endOfStream
                return nil
            }
            if let readError {
                throw EngineError.runtimeFailure(
                    message: "дорожка не читается: \(path): \(readError.localizedDescription)"
                )
            }
            if status == .error {
                let reason = conversionError?.localizedDescription ?? "неизвестная ошибка"
                throw EngineError.runtimeFailure(message: "ошибка преобразования дорожки: \(path): \(reason)")
            }
            if let channel = out.floatChannelData?[0], out.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
            if status == .endOfStream { return samples }
        }
    }
}

/// Источник блоков исходной частоты для `AVAudioConverter`: каждый вызов — новый буфер (конвертер
/// вправе держать предыдущий), конец — пустое чтение либо исчерпанный остаток вырезки.
private final class BlockSource {
    /// `eofErr` (MacErrors.h) литералом: имя из CarbonCore не во всех SDK видно через `AVFoundation`.
    private static let endOfFileStatus = -39

    let file: AVAudioFile
    private(set) var remaining: AVAudioFramePosition?

    init(file: AVAudioFile, remaining: AVAudioFramePosition?) {
        self.file = file
        self.remaining = remaining
    }

    var expectedFrames: AVAudioFramePosition? {
        let tail = max(0, file.length - file.framePosition)
        guard let remaining else { return tail }
        return min(remaining, tail)
    }

    func next() throws -> AVAudioPCMBuffer? {
        var capacity = AudioTrackReader.blockFrames
        if let remaining {
            guard remaining > 0 else { return nil }
            capacity = AVAudioFrameCount(min(AVAudioFramePosition(capacity), remaining))
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else {
            return nil
        }
        do {
            try file.read(into: buffer, frameCount: capacity)
        } catch let error as NSError where error.code == Self.endOfFileStatus {
            // Чтение на самом конце файла Core Audio отдаёт ошибкой `eofErr` (−39), а не
            // пустым буфером — это конец потока, а не отказ.
            return nil
        }
        guard buffer.frameLength > 0 else { return nil }
        if let remaining { self.remaining = remaining - AVAudioFramePosition(buffer.frameLength) }
        return buffer
    }
}
