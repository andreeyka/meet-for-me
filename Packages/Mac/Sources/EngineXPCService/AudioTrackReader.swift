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
//  ШКАЛА — C-011 v7, инвариант 16 (IR-148). `offsetMs` — позиция на шкале записи, где лежит
//  кадр 0 файла; позиция в файле = позиция на шкале − `offsetMs`. Из файла ничего не
//  отрезается: `read(AudioRef)` отдаёт файл целиком. Вырезка `AudioSlice`: первый кадр —
//  `round((startMs − offsetMs) · sampleRate / 1000)`, кадр за последним — та же формула от
//  `endMs`; `round` — до ближайшего, половина от нуля. Конец за концом файла обрезается по
//  концу файла. `startMs < offsetMs` и вырезка без единого кадра после обрезки —
//  `unsupportedRequest`.
//
//  ПОТОКОВО. Файл читается блоками по `blockFrames` кадров исходной частоты; каждый блок сразу
//  уходит в `AVAudioConverter` (передискретизация и сведение в моно, `downmix = true` — среднее
//  каналов, проверено тестом на стерео с разной громкостью каналов). В памяти целиком — только
//  итог 16 кГц моно: около 230 МБ Float32 на час.
//
//  CAF С ДЛИНОЙ −1 (К27(б) C-004: запись оборвана `SIGKILL`). `data`-чанк заявленной длины −1
//  по спецификации CAF тянется до конца файла; Core Audio так его и читает и выводит
//  `AVAudioFile.length` из размера файла (неполный последний кадр отброшен). Цикл чтения идёт
//  до этой длины — заявленная −1 на результат не влияет.
//
//  ОТКАЗЫ — C-011 v7, инвариант 17 (IR-148). Файла нет, он не открывается, не разбирается как
//  аудио либо чтение оборвалось — `audioUnreadable(path:)` с путём из `fileURL`. Заголовок не
//  совпал с `AudioRef` (`sampleRate` или число каналов) — `unsupportedRequest(message:)` с
//  заявленным и найденным значениями. Оба перманентны (C-012 §4); `runtimeFailure` остаётся
//  только за сбоем самого преобразования (конвертер, буфер), к файлу отношения не имеющим.
//  «Чтение оборвалось» — и бросок `AVAudioFile.read`, и пустое чтение (`frameLength == 0`) до
//  конца вырезки: конвертер принимает пустой ответ источника за конец потока, так что без
//  отказа дорожка молча обрезалась бы. По той же причине невыделенный буфер блока — не конец
//  потока, а `runtimeFailure` (MEE-491).
//
//  ФАЙЛ БЕЗ ЕДИНОГО КАДРА — C-011 v8, инвариант 17, «Файл без кадров» (IR-154, MEE-493 п. 1).
//  Заголовок разобран и совпал с `AudioRef`, а `data` пуст (`length == 0`): файл не
//  нечитаемый, `read(AudioRef)` отдаёт `[]` без ошибки, `durationMs(of:)` — 0. Вырезка из
//  файла без кадров — `unsupportedRequest` по инв. 16 (ни одного кадра после обрезки). Движок по
//  длительности 0 не читает дорожку вовсе и даёт ноль сегментов канала (MEE-509). Файл короче
//  1 мс (меньше `sampleRate / 1000` кадров) тоже даёт длительность 0, и движок считает его
//  дорожкой без кадров.

import AVFoundation
import EngineKit
import Foundation

public enum AudioTrackReader {

    /// Частота результата — вход ASR (GigaAM v3, спайк R12).
    public static let outputSampleRate = 16_000

    /// Кадров исходной частоты на блок чтения: секунда при 48 кГц.
    static let blockFrames: AVAudioFrameCount = 48_000

    /// Выделение буфера блока исходной частоты. Отказ `AVAudioPCMBuffer` синтетическим файлом
    /// не вызвать, поэтому тест подменяет выделение отказом (MEE-491). `@Sendable` — к переходу
    /// на Swift 6 / strict concurrency (MEE-488, п. 7).
    typealias BufferAllocator = @Sendable (AVAudioFormat, AVAudioFrameCount) -> AVAudioPCMBuffer?

    static let systemAllocator: BufferAllocator = { AVAudioPCMBuffer(pcmFormat: $0, frameCapacity: $1) }

    /// Вся дорожка, от кадра 0 файла до конца (`offsetMs` ничего не отрезает — инв. 16).
    /// Файл без единого кадра — `[]` без ошибки (C-011 v8 инв. 17; шапка, «Файл без единого кадра»).
    public static func read(_ ref: AudioRef) throws -> [Float] {
        try read(ref, allocate: systemAllocator)
    }

    /// Шов для тестов: подменяемые выделение буфера (MEE-491) и чтение блока — сквозной тест
    /// пустого чтения через `read(...)` (MEE-488, п. 9).
    static func read(
        _ ref: AudioRef, allocate: @escaping BufferAllocator,
        readBlock: @escaping BlockSource.BlockReader = BlockSource.fileReader
    ) throws -> [Float] {
        let file = try open(ref)
        return try convert(
            file, frames: 0..<file.length, path: ref.fileURL.path, allocate: allocate, readBlock: readBlock
        )
    }

    /// Вырезка `startMs..<endMs` на шкале записи (инв. 16).
    public static func read(_ slice: AudioSlice) throws -> [Float] {
        try read(slice, readBlock: BlockSource.fileReader)
    }

    /// Длительность файла дорожки, мс: `length · 1000 / sampleRate` с отбросом дробной части —
    /// последний неполный миллисекундный отрезок не входит (MEE-504). Время в файле, без
    /// `offsetMs`. Отказы — те же, что у `read` (инв. 17): нет файла, не разбирается —
    /// `audioUnreadable`; заголовок не совпал с `AudioRef` — `unsupportedRequest`.
    public static func durationMs(of ref: AudioRef) throws -> Int {
        let file = try open(ref)
        return Int(file.length * 1_000 / AVAudioFramePosition(ref.sampleRate))
    }

    /// Диапазон `[fromMs; toMs)` ВРЕМЕНИ В ФАЙЛЕ (кадр 0 = 0 мс), а не шкалы записи: вход порта
    /// `GigaAMAudioSource` (MEE-504). Сводится к вырезке `AudioSlice` со сдвигом на `offsetMs`
    /// (инв. 16) — та же формула кадров, та же обрезка конца по концу файла. Диапазон, который
    /// `AudioSlice` не принимает (`fromMs < 0`, `toMs <= fromMs`), — `unsupportedRequest`.
    public static func read(_ ref: AudioRef, fromMs: Int, toMs: Int) throws -> [Float] {
        let slice: AudioSlice
        do {
            slice = try AudioSlice(source: ref, startMs: fromMs + ref.offsetMs, endMs: toMs + ref.offsetMs)
        } catch {
            throw EngineError.unsupportedRequest(
                message: "диапазон \(fromMs)..<\(toMs) мс файла не является вырезкой: \(error)"
            )
        }
        return try read(slice)
    }

    static func read(_ slice: AudioSlice, readBlock: @escaping BlockSource.BlockReader) throws -> [Float] {
        let ref = slice.source
        let file = try open(ref)
        let range = try frameRange(
            startMs: slice.startMs, endMs: slice.endMs, offsetMs: ref.offsetMs,
            sampleRate: ref.sampleRate, fileLength: file.length
        )
        return try convert(
            file, frames: range, path: ref.fileURL.path, allocate: systemAllocator, readBlock: readBlock
        )
    }

    // MARK: - Шкала (инв. 16)

    /// Кадры файла для вырезки `startMs..<endMs` на шкале записи: `round((ms − offsetMs) ·
    /// sampleRate / 1000)` на обоих концах, конец обрезан по `fileLength`.
    static func frameRange(
        startMs: Int, endMs: Int, offsetMs: Int, sampleRate: Int, fileLength: AVAudioFramePosition
    ) throws -> Range<AVAudioFramePosition> {
        guard startMs >= offsetMs else {
            throw EngineError.unsupportedRequest(
                message: "начало среза \(startMs) мс раньше начала файла на шкале записи (offsetMs \(offsetMs))"
            )
        }
        let first = frame(ms: startMs - offsetMs, sampleRate: sampleRate)
        let last = min(frame(ms: endMs - offsetMs, sampleRate: sampleRate), fileLength)
        guard last > first else {
            throw EngineError.unsupportedRequest(message: """
                срез \(startMs)..<\(endMs) мс (offsetMs \(offsetMs)) не содержит ни одного кадра файла \
                длиной \(fileLength) кадров
                """)
        }
        return first..<last
    }

    /// `round(ms · sampleRate / 1000)`, половина — от нуля. В целых: без погрешности `Double`.
    static func frame(ms: Int, sampleRate: Int) -> AVAudioFramePosition {
        let scaled = Int64(ms) * Int64(sampleRate)
        let (quotient, remainder) = scaled.quotientAndRemainder(dividingBy: 1000)
        let roundsAway = abs(remainder) * 2 >= 1000
        return AVAudioFramePosition(quotient + (roundsAway ? (scaled < 0 ? -1 : 1) : 0))
    }

    // MARK: - Файл (инв. 17)

    private static func open(_ ref: AudioRef) throws -> AVAudioFile {
        let path = ref.fileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw EngineError.audioUnreadable(path: path)
        }
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: ref.fileURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw EngineError.audioUnreadable(path: path)
        }
        let header = file.fileFormat
        if Double(ref.sampleRate) != header.sampleRate || ref.channelCount != Int(header.channelCount) {
            throw EngineError.unsupportedRequest(message: """
                заголовок дорожки не совпадает с AudioRef: \(path): \
                sampleRate AudioRef \(ref.sampleRate), файл \(Int(header.sampleRate)); \
                channelCount AudioRef \(ref.channelCount), файл \(header.channelCount)
                """)
        }
        return file
    }

    // MARK: - Преобразование

    private static func convert(
        _ file: AVAudioFile, frames: Range<AVAudioFramePosition>, path: String,
        allocate: @escaping BufferAllocator, readBlock: @escaping BlockSource.BlockReader
    ) throws -> [Float] {
        guard !frames.isEmpty else { return [] }
        file.framePosition = frames.lowerBound
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(outputSampleRate),
            channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw EngineError.runtimeFailure(
                message: "нет преобразования \(file.processingFormat) → 16000 Гц моно: \(path)"
            )
        }
        converter.downmix = true
        let source = BlockSource(
            file: file, remaining: AVAudioFramePosition(frames.count), path: path,
            allocate: allocate, readBlock: readBlock
        )
        return try convert(from: source, with: converter, into: target, path: path)
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
                // Отказ источника уже назван по инв. 17 (`BlockSource.next`): `audioUnreadable`
                // за обрыв чтения, `runtimeFailure` за невыделенный буфер.
                throw readError
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
/// вправе держать предыдущий), конец — достигнутый `AVAudioFile.length` либо исчерпанный остаток
/// вырезки. Всё прочее — отказ, а не конец: `nil` конвертер принял бы за конец потока.
final class BlockSource {
    let file: AVAudioFile
    private(set) var remaining: AVAudioFramePosition?
    private let path: String
    private let allocate: AudioTrackReader.BufferAllocator
    private let readBlock: BlockReader

    /// Чтение блока из файла. Пустое чтение раньше `length` синтетическим CAF не вызвать (на
    /// обрезанном файле Core Audio бросает), поэтому тест подменяет чтение пустым (MEE-491).
    typealias BlockReader = @Sendable (AVAudioFile, AVAudioPCMBuffer, AVAudioFrameCount) throws -> Void

    /// Чтение по умолчанию — `AVAudioFile.read(into:frameCount:)`.
    static let fileReader: BlockReader = { try $0.read(into: $1, frameCount: $2) }

    init(
        file: AVAudioFile, remaining: AVAudioFramePosition?, path: String,
        allocate: @escaping AudioTrackReader.BufferAllocator = AudioTrackReader.systemAllocator,
        readBlock: @escaping BlockReader = BlockSource.fileReader
    ) {
        self.file = file
        self.remaining = remaining
        self.path = path
        self.allocate = allocate
        self.readBlock = readBlock
    }

    var expectedFrames: AVAudioFramePosition? {
        let tail = max(0, file.length - file.framePosition)
        guard let remaining else { return tail }
        return min(remaining, tail)
    }

    /// `nil` — только конец: кадров до `length` (и до конца вырезки) не осталось. Невыделенный
    /// буфер — `runtimeFailure`; бросок чтения и пустое чтение раньше конца — `audioUnreadable`
    /// (инв. 17, MEE-491).
    ///
    /// Конец потока определяется по `AVAudioFile.length`, а не по ошибке чтения: чтение за
    /// концом файла Core Audio отдаёт ошибкой, и её вид зависит от версии ОС (`eofErr` −39 на
    /// macOS 27, `_GenericObjCError` 0 на macOS 14). У CAF с длиной −1 `length` выводится из
    /// размера файла — то есть тоже «до конца файла», с отброшенным неполным последним кадром.
    func next() throws -> AVAudioPCMBuffer? {
        var frames = max(0, file.length - file.framePosition)
        if let remaining { frames = min(frames, remaining) }
        frames = min(frames, AVAudioFramePosition(AudioTrackReader.blockFrames))
        guard frames > 0 else { return nil }
        let capacity = AVAudioFrameCount(frames)
        guard let buffer = allocate(file.processingFormat, capacity) else {
            throw EngineError.runtimeFailure(
                message: "не выделен буфер блока на \(capacity) кадров: \(path)"
            )
        }
        do {
            try readBlock(file, buffer, capacity)
        } catch {
            throw EngineError.audioUnreadable(path: path)
        }
        // Пустое чтение до конца вырезки — обрыв чтения, инв. 17 (не конец потока).
        guard buffer.frameLength > 0 else { throw EngineError.audioUnreadable(path: path) }
        if let remaining { self.remaining = remaining - AVAudioFramePosition(buffer.frameLength) }
        return buffer
    }
}
