//  Фейки и основа тестов GigaAMEngine — MEE-502 (Z3б): источник, распознаватель, фабрика, журнал прогресса.

import DomainCore
import DomainTestKit
import EngineKit
import Foundation
import XCTest
@testable import GigaAM

// MARK: - Фейки

/// Источник: синтетика вместо файла. Амплитуда — по каналу, тишина каждые 4,7 с на 400 мс.
final class FakeAudioSource: GigaAMAudioSource, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [(fromMs: Int, toMs: Int)] = []
    var durations: [UUID: Int] = [:]
    var failure: Error?

    func durationMs(of audio: AudioRef) throws -> Int {
        if let failure { throw failure }
        return durations[audio.recordingId] ?? 0
    }

    func read(_ audio: AudioRef, fromMs: Int, toMs: Int) throws -> [Float] {
        lock.lock()
        requests.append((fromMs, toMs))
        lock.unlock()
        let amplitude: Float = audio.channel == .system ? 0.5 : 0.25
        var samples: [Float] = []
        samples.reserveCapacity((toMs - fromMs) * 16)
        for ms in fromMs..<toMs {
            let value: Float = ms % 4_700 < 400 ? 0 : amplitude
            samples.append(contentsOf: [Float](repeating: value, count: 16))
        }
        return samples
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests.count
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
        let word = samples.first == 0.5 ? "система" : "микрофон"
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

    override func setUpWithError() throws {
        modelDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        try writeModelFiles()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: modelDirectory)
    }

    func writeModelFiles() throws {
        for name in [GigaAMEngine.modelFileName, GigaAMEngine.tokensFileName] {
            try Data([0]).write(to: modelDirectory.appendingPathComponent(name))
        }
    }

    func makeEngine(factoryFailure: Error? = nil) -> GigaAMEngine {
        let fixed = fixedDate
        return GigaAMEngine(
            audioSource: source, recognizerFactory: FakeFactory(recognizer: recognizer, failure: factoryFailure),
            clock: { fixed }
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
