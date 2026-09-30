//  SherpaGigaAMRecognizer — реализация порта `GigaAMRecognizer` поверх sherpa-onnx.
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок (адаптер, macOS)
//
//  IR-152 (MEE-486, п. 1 и Z5), MEE-503. Единственное место репозитория, где разрешён
//  `import SherpaOnnx` (docs/module-map.md, модуль gigaam). Mel, CTC-декодирование и токенизация —
//  внутри sherpa-onnx; здесь только конфигурация и перевод результата в `RecognizedChunk`.
//
//  Конфигурация — как у стенда R12 (`spikes/GigaAMSpike`, MEE-426): `nemo_ctc`, `featureDim` 64,
//  16 кГц, CPU, 4 потока, жадный CTC (`greedy_search`). Метки токенов — `tokens_arr`/`timestamps`
//  результата, тот же путь, что `--timestamps` стенда.
//
//  Рекогнайзер создаётся через C API, а не через обёртку `SherpaOnnxOfflineRecognizer`: обёртка
//  на неудачной загрузке зовёт `fatalError`, а адаптер обязан вернуть ошибку.

import Foundation
import GigaAM
import SherpaOnnx
import SherpaOnnxC

/// Фабрика распознавателя GigaAM v3 `e2e_ctc` по каталогу модели.
public struct SherpaGigaAMRecognizerFactory: GigaAMRecognizerFactory {

    /// Файлы модели в каталоге (имена локальные, `files[].name` каталога, C-014).
    public static let modelFileName = "model.int8.onnx"
    public static let tokensFileName = "tokens.txt"

    public init() {}

    /// Загружает модель. Нет `model.int8.onnx` или `tokens.txt` — `GigaAMRecognizerError.modelFilesMissing`
    /// (движок сводит к `modelMissing`); рантайм не создал распознаватель — `.runtimeFailure`.
    public func makeRecognizer(modelDirectory: URL) throws -> any GigaAMRecognizer {
        try SherpaGigaAMRecognizer(modelDirectory: modelDirectory)
    }
}

/// Распознаватель одного куска записи. Вызовы `recognize` сериализованы замком: один экземпляр
/// на вызов `transcribe`, но порт `Sendable`, и рантайм не обещает потокобезопасности.
public final class SherpaGigaAMRecognizer: GigaAMRecognizer, @unchecked Sendable {

    static let sampleRate = 16_000
    static let featureDim = 64
    static let threadCount = 4
    /// Больше 30 с движок не подаёт (инвариант 19 C-011). Экспорт модели падает за ~200 с
    /// аварийным завершением процесса (R12), поэтому длинный вход отклоняется ошибкой заранее.
    static let maxSamples = 30 * sampleRate

    private let recognizer: OpaquePointer
    private let lock = NSLock()

    /// - Throws: `GigaAMRecognizerError.modelFilesMissing`, `.runtimeFailure(message:)`.
    public init(modelDirectory: URL) throws {
        let model = modelDirectory.appendingPathComponent(SherpaGigaAMRecognizerFactory.modelFileName)
        let tokens = modelDirectory.appendingPathComponent(SherpaGigaAMRecognizerFactory.tokensFileName)
        guard Self.isRegularFile(model), Self.isRegularFile(tokens) else {
            throw GigaAMRecognizerError.modelFilesMissing
        }
        guard let created = Self.createRecognizer(model: model.path, tokens: tokens.path) else {
            throw GigaAMRecognizerError.runtimeFailure(message: "sherpa-onnx не создал распознаватель")
        }
        recognizer = created
    }

    deinit {
        SherpaOnnxDestroyOfflineRecognizer(recognizer)
    }

    public func recognize(samples: [Float]) throws -> RecognizedChunk {
        try Self.checkChunkLength(samples.count)
        lock.lock()
        defer { lock.unlock() }
        guard let stream = SherpaOnnxCreateOfflineStream(recognizer) else {
            throw GigaAMRecognizerError.runtimeFailure(message: "sherpa-onnx не создал поток")
        }
        defer { SherpaOnnxDestroyOfflineStream(stream) }
        samples.withUnsafeBufferPointer { buffer in
            SherpaOnnxAcceptWaveformOffline(stream, Int32(Self.sampleRate), buffer.baseAddress, Int32(buffer.count))
        }
        SherpaOnnxDecodeOfflineStream(recognizer, stream)
        guard let result = SherpaOnnxGetOfflineStreamResult(stream) else {
            throw GigaAMRecognizerError.runtimeFailure(message: "sherpa-onnx не вернул результат")
        }
        defer { SherpaOnnxDestroyOfflineRecognizerResult(result) }
        return try Self.chunk(from: result.pointee)
    }

    // MARK: - Внутреннее

    /// Порог длины куска: не больше `maxSamples` отсчётов (30 с), иначе `.runtimeFailure`.
    /// Вынесен отдельно, чтобы проверяться без модели.
    static func checkChunkLength(_ sampleCount: Int) throws {
        guard sampleCount <= maxSamples else {
            throw GigaAMRecognizerError.runtimeFailure(
                message: "кусок \(sampleCount) отсчётов длиннее \(maxSamples) (30 с)"
            )
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }

    /// Строки конфигурации живут до конца вызова: `SherpaOnnxCreateOfflineRecognizer` копирует их.
    private static func createRecognizer(model: String, tokens: String) -> OpaquePointer? {
        autoreleasepool {
            let modelConfig = sherpaOnnxOfflineModelConfig(
                tokens: tokens,
                nemoCtc: sherpaOnnxOfflineNemoEncDecCtcModelConfig(model: model),
                numThreads: threadCount,
                provider: "cpu",
                modelType: "nemo_ctc"
            )
            var config = sherpaOnnxOfflineRecognizerConfig(
                featConfig: sherpaOnnxFeatureConfig(sampleRate: sampleRate, featureDim: featureDim),
                modelConfig: modelConfig,
                decodingMethod: "greedy_search"
            )
            return SherpaOnnxCreateOfflineRecognizer(&config)
        }
    }

    private static func chunk(from raw: SherpaOnnxOfflineRecognizerResult) throws -> RecognizedChunk {
        let text = raw.text.map { String(cString: $0) } ?? ""
        let count = Int(raw.count)
        guard count > 0 else {
            return RecognizedChunk(text: text, tokens: [], timestamps: [])
        }
        guard let tokensArray = raw.tokens_arr, let stamps = raw.timestamps else {
            throw GigaAMRecognizerError.runtimeFailure(message: "sherpa-onnx не выдал метки токенов")
        }
        var tokens: [String] = []
        var timestamps: [Double] = []
        tokens.reserveCapacity(count)
        timestamps.reserveCapacity(count)
        for index in 0..<count {
            tokens.append(portToken(tokensArray[index].map { String(cString: $0) } ?? ""))
            timestamps.append(Double(stamps[index]))
        }
        return RecognizedChunk(text: text, tokens: tokens, timestamps: timestamps)
    }

    /// sherpa-onnx отдаёт в `tokens_arr` маркер начала слова `▁` уже заменённым на пробел;
    /// порт `GigaAMRecognizer` обещает `▁` — возвращаем его.
    static func portToken(_ raw: String) -> String {
        guard raw.first == " " else { return raw }
        return wordMarker + raw.dropFirst()
    }

    static let wordMarker = "\u{2581}"
}
