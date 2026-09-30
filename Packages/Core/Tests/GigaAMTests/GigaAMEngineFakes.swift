//  Фейки и основа тестов GigaAMEngine — MEE-502 (Z3б): источник, распознаватель, фабрика, журнал прогресса.
//  MEE-513: каталог модели основы пишет и `.manifest.json` — без него движок отвечает `modelMissing`.

import DomainCore
import DomainTestKit
import EngineKit
import Foundation
import XCTest
@testable import GigaAM

// MARK: - Фейки

/// Источник: синтетика вместо файла. Амплитуда — по каналу, тишина каждые 4,7 с на 400 мс (с 0 мс).
/// `leadingSilenceMs` задан — вместо этого тишина только в первые `leadingSilenceMs` мс дорожки.
final class FakeAudioSource: GigaAMAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(fromMs: Int, toMs: Int)] = []
    private var requestChannels: [RecordingManifest.Channel] = []
    var durations: [UUID: Int] = [:]
    /// Длительность канала поверх `durations` — дорожка без кадров (0 мс) у одного канала (MEE-509).
    var channelDurations: [RecordingManifest.Channel: Int] = [:]
    var failure: Error?
    var leadingSilenceMs: Int?

    /// Тишина на миллисекунде `ms` файла.
    func isSilent(atMs ms: Int) -> Bool {
        if let leadingSilenceMs { return ms < leadingSilenceMs }
        return ms % 4_700 < 400
    }

    func durationMs(of audio: AudioRef) throws -> Int {
        if let failure { throw failure }
        return channelDurations[audio.channel] ?? durations[audio.recordingId] ?? 0
    }

    func read(_ audio: AudioRef, fromMs: Int, toMs: Int) throws -> [Float] {
        lock.lock()
        requests.append((fromMs, toMs))
        requestChannels.append(audio.channel)
        lock.unlock()
        let amplitude: Float = audio.channel == .system ? 0.5 : 0.25
        var samples: [Float] = []
        samples.reserveCapacity((toMs - fromMs) * 16)
        for ms in fromMs..<toMs {
            let value: Float = isSilent(atMs: ms) ? 0 : amplitude
            samples.append(contentsOf: [Float](repeating: value, count: 16))
        }
        return samples
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
    }
    var requestedChannels: Set<RecordingManifest.Channel> {
        lock.lock()
        defer { lock.unlock() }
        return Set(requestChannels)
    }
    var longestRequestMs: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.map { $0.toMs - $0.fromMs }.max() ?? 0
    }
}

/// Распознаватель: бросает на входе > 200 с, как настоящий рантайм; слово — по амплитуде первого отсчёта.
final class FakeRecognizer: GigaAMRecognizer, @unchecked Sendable {
    private let lock = NSLock()
    private var lengths: [Int] = []
    var failure: Error?
    var cancelOnCall: Int?

    func recognize(samples: [Float]) throws -> RecognizedChunk {
        lock.lock()
        lengths.append(samples.count)
        let call = lengths.count
        lock.unlock()
        guard samples.count <= 200 * 16_000 else {
            throw GigaAMRecognizerError.runtimeFailure(message: "вход > 200 с")
        }
        if let failure { throw failure }
        if call == cancelOnCall { withUnsafeCurrentTask { $0?.cancel() } }
        let word = samples.contains(0.5) ? "система" : "микрофон"
        return RecognizedChunk(text: word, tokens: ["\u{2581}\(word)", "."], timestamps: [0, 0.12])
    }

    var calls: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return lengths
    }
}

struct FakeFactory: GigaAMRecognizerFactory {
    let recognizer: FakeRecognizer
    var failure: Error?

    func makeRecognizer(modelDirectory: URL) throws -> any GigaAMRecognizer {
        if let failure { throw failure }
        return recognizer
    }
}

/// Журнал движка (замыкание `log`): строки в порядке записи.
final class EngineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func append(_ line: String) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [EngineProgress] = []
    func append(_ event: EngineProgress) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    var events: [EngineProgress] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

// MARK: - Основа тестов

class GigaAMEngineTestCase: XCTestCase {

    let recordingId = UUID()
    let source = FakeAudioSource()
    let recognizer = FakeRecognizer()
    var modelDirectory = URL(fileURLWithPath: "/nonexistent")
    let fixedDate = Date(timeIntervalSince1970: 1_789_000_000)
    let engineLog = EngineLog()

    override func setUpWithError() throws {
        modelDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try writeModelFiles()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    /// Файлы модели по одному байту и манифест с теми же длинами.
    func writeModelFiles() throws {
        for name in [GigaAMEngine.modelFileName, GigaAMEngine.tokensFileName] {
            try Data([0]).write(to: modelDirectory.appendingPathComponent(name))
        }
        try writeManifest(modelBytes: 1, tokensBytes: 1)
    }

    var manifestURL: URL { modelDirectory.appendingPathComponent(ModelManifestFile.fileName) }

    func writeManifest(
        modelBytes: Int64, tokensBytes: Int64, names: [String]? = nil,
        schemaVersion: Int = ModelManifestFile.supportedSchemaVersion,
        id: String = "gigaam-v3-e2e-ctc-int8", version: String = "3.0.0"
    ) throws {
        let url = URL(string: "https://example.invalid/model")!
        let hash = String(repeating: "0", count: 64)
        let names = names ?? [GigaAMEngine.modelFileName, GigaAMEngine.tokensFileName]
        let files = zip(names, [modelBytes, tokensBytes]).map {
            ModelFile(name: $0, url: url, sha256: hash, sizeBytes: $1)
        }
        let descriptor = ModelDescriptor(
            id: id, version: version, role: .asr, engine: "sherpaonnx", runtime: .onnx,
            displayName: "GigaAM", description: "", sizeBytes: modelBytes + tokensBytes, languages: ["ru"],
            files: files, quantization: "int8", minChip: .m2, minRAMGB: 8, recommendedFor: []
        )
        let manifest = ModelManifestFile(schemaVersion: schemaVersion, descriptor: descriptor)
        try DomainJSON.encode(manifest).write(to: manifestURL)
        // Манифест поддерживаемой версии обязан разбираться — иначе тест проверял бы ветку «манифест
        // не читается». Чужую версию разбор отвергает — её тест и проверяет (MEE-514).
        if schemaVersion == ModelManifestFile.supportedSchemaVersion {
            _ = try DomainJSON.decode(ModelManifestFile.self, from: Data(contentsOf: manifestURL))
        }
    }

    func makeEngine(factoryFailure: Error? = nil) -> GigaAMEngine {
        makeEngine(factory: FakeFactory(recognizer: recognizer, failure: factoryFailure))
    }

    func makeEngine(factory: any GigaAMRecognizerFactory) -> GigaAMEngine {
        let fixed = fixedDate
        let log = engineLog
        return GigaAMEngine(
            audioSource: source, recognizerFactory: factory, clock: { fixed }, log: { log.append($0) }
        )
    }

    func audioRef(_ channel: RecordingManifest.Channel, id: UUID? = nil, offsetMs: Int = 0) throws -> AudioRef {
        return try AudioRef(
            recordingId: id ?? recordingId, channel: channel,
            fileURL: URL(fileURLWithPath: "/audio/\(channel.rawValue).wav"),
            sampleRate: 16_000, channelCount: 1, offsetMs: offsetMs
        )
    }

    func request(
        _ audio: [AudioRef], language: String? = nil, words: Bool = true
    ) throws -> TranscriptionRequest {
        let model = ModelBundle(
            modelId: "gigaam-v3-e2e-ctc-int8", version: "3.0.0", role: .asr, runtime: .onnx,
            directoryURL: modelDirectory
        )
        return try TranscriptionRequest(
            audio: audio, language: language, wantWordTimestamps: words, asrModel: model, vadModel: nil
        )
    }

    func run(
        _ request: TranscriptionRequest, log: ProgressLog = ProgressLog(), engine: GigaAMEngine? = nil
    ) async throws -> Transcript {
        try await (engine ?? makeEngine()).transcribe(request) { log.append($0) }
    }

    func assertEngineError(
        _ expected: EngineError, _ request: TranscriptionRequest, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await run(request)
            XCTFail("ожидалась \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? EngineError, expected, file: file, line: line)
        }
    }
}
