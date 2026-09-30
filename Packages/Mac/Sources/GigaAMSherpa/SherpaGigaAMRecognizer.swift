//  SherpaGigaAMRecognizer — реализация порта `GigaAMRecognizer` поверх sherpa-onnx.
//
//  Модуль: gigaam · Владелец: DEV-2 · Слой: движок (адаптер, macOS)
//
//  IR-152 (MEE-486, п. 1 и Z5), MEE-503. Единственное место репозитория, где разрешён
//  `import SherpaOnnxC` (docs/module-map.md v1.23, модуль gigaam). Mel, CTC-декодирование и
//  токенизация — внутри sherpa-onnx; здесь только конфигурация и перевод результата в `RecognizedChunk`.
//
//  Конфигурация — как у стенда R12 (`spikes/GigaAMSpike`, MEE-426): `nemo_ctc`, `featureDim` 64,
//  16 кГц, CPU, 4 потока, жадный CTC (`greedy_search`). Метки токенов — `tokens_arr`/`timestamps`
//  результата, тот же путь, что `--timestamps` стенда.
//
//  Только C API (IR-156, MEE-512): Swift-обёртки пакета sherpa-onnx в сборке нет — `Package.swift`
//  подключает статический XCFramework `SherpaOnnxC` напрямую. Конфигурацию собирает
//  `withRecognizerConfig` C-структурами; значения полей те же, что ставила обёртка
//  (`sherpaOnnxOfflineRecognizerConfig` и соседи sherpa-onnx 1.13.8), остальные — нули, которые
//  C API сам заменяет своими умолчаниями.

import Foundation
import GigaAM
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

    private static func createRecognizer(model: String, tokens: String) -> OpaquePointer? {
        withRecognizerConfig(model: model, tokens: tokens) { SherpaOnnxCreateOfflineRecognizer($0) }
    }

    /// Собирает конфигурацию распознавателя и отдаёт её `body`. Строки конфигурации — копии
    /// в памяти C (`strdup`), живут ровно до выхода из `body` и освобождаются здесь же:
    /// `SherpaOnnxCreateOfflineRecognizer` копирует их к себе, указатели за `body` не уходят.
    /// Числа, отличные от нуля, — умолчания обёртки sherpa-onnx 1.13.8 (`modeling_unit`,
    /// `max_active_paths`, `hotwords_score`, `lm_config.scale`), чтобы поведение не менялось.
    static func withRecognizerConfig<Result>(
        model: String,
        tokens: String,
        _ body: (UnsafePointer<SherpaOnnxOfflineRecognizerConfig>) throws -> Result
    ) rethrows -> Result {
        var owned: [UnsafeMutablePointer<CChar>] = []
        defer { owned.forEach { free($0) } }
        func cString(_ value: String) -> UnsafePointer<CChar> {
            guard let copy = strdup(value) else { fatalError("strdup: нет памяти под строку конфигурации") }
            owned.append(copy)
            return UnsafePointer(copy)
        }

        var config = SherpaOnnxOfflineRecognizerConfig()
        config.feat_config.sample_rate = Int32(sampleRate)
        config.feat_config.feature_dim = Int32(featureDim)
        config.model_config.nemo_ctc.model = cString(model)
        config.model_config.tokens = cString(tokens)
        config.model_config.num_threads = Int32(threadCount)
        config.model_config.debug = 0
        config.model_config.provider = cString("cpu")
        config.model_config.model_type = cString("nemo_ctc")
        config.model_config.modeling_unit = cString("cjkchar")
        config.lm_config.scale = 1.0
        config.decoding_method = cString("greedy_search")
        config.max_active_paths = 4
        config.hotwords_score = 1.5
        config.blank_penalty = 0
        return try withUnsafePointer(to: &config) { try body($0) }
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
