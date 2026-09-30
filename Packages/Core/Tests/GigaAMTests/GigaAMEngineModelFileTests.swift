//  GigaAMEngineModelFileTests — MEE-504 (Z6), замечание ревью (а): файл модели, чья длина не
//  совпала с `files[].sizeBytes` `.manifest.json`, — `modelMissing` ДО фабрики распознавателя (иначе
//  onnxruntime на обрезанном `.onnx` завершает процесс сервиса `std::terminate`).

import DomainCore
import DomainTestKit
import EngineKit
import Foundation
import XCTest
@testable import GigaAM

final class GigaAMEngineModelFileTests: GigaAMEngineTestCase {

    private let expected = EngineError.modelMissing(modelId: "gigaam-v3-e2e-ctc-int8", version: "3.0.0")

    /// Файлы тестового каталога — по одному байту (`writeModelFiles`).
    func testManifestSizesMatchingFilesPass() async throws {
        source.durations[recordingId] = 3_000
        try writeManifest(modelBytes: 1, tokensBytes: 1)
        _ = try await run(try request([try audioRef(.system)]), engine: engine)
        XCTAssertEqual(factory.makeCount, 1)
    }

    func testTruncatedModelFileIsModelMissingBeforeFactoryAndAudio() async throws {
        source.durations[recordingId] = 3_000
        for (modelBytes, tokensBytes) in [(319_869_121, 1), (1, 2_006)] {
            try writeManifest(modelBytes: Int64(modelBytes), tokensBytes: Int64(tokensBytes))
            await assertEngineError(expected, try request([try audioRef(.system)]), engine: engine)
        }
        XCTAssertEqual(factory.makeCount, 0)
        XCTAssertEqual(source.requestCount, 0)
    }

    func testSymlinkedModelFileIsMeasuredAtItsTarget() async throws {
        source.durations[recordingId] = 3_000
        let target = modelDirectory.appendingPathComponent("real.onnx")
        try Data(count: 5).write(to: target)
        let link = modelDirectory.appendingPathComponent(GigaAMEngine.modelFileName)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try writeManifest(modelBytes: 5, tokensBytes: 1)
        _ = try await run(try request([try audioRef(.system)]), engine: engine)
        XCTAssertEqual(factory.makeCount, 1)
    }

    func testWithoutManifestOrWithUnreadableManifestNoSizeCheck() async throws {
        source.durations[recordingId] = 3_000
        _ = try await run(try request([try audioRef(.system)]), engine: engine)
        try Data("{".utf8).write(to: manifestURL)
        _ = try await run(try request([try audioRef(.system)]), engine: engine)
        XCTAssertEqual(factory.makeCount, 2)
    }

    // MARK: - Опоры

    private lazy var factory = CountingFactory(recognizer: recognizer)
    private lazy var engine = GigaAMEngine(audioSource: source, recognizerFactory: factory)

    private var manifestURL: URL { modelDirectory.appendingPathComponent(GigaAMEngine.manifestFileName) }

    private func writeManifest(modelBytes: Int64, tokensBytes: Int64) throws {
        let url = URL(string: "https://example.invalid/model")!
        let hash = String(repeating: "0", count: 64)
        let files = [
            ModelFile(name: GigaAMEngine.modelFileName, url: url, sha256: hash, sizeBytes: modelBytes),
            ModelFile(name: GigaAMEngine.tokensFileName, url: url, sha256: hash, sizeBytes: tokensBytes)
        ]
        let descriptor = ModelDescriptor(
            id: "gigaam-v3-e2e-ctc-int8", version: "3.0.0", role: .asr, engine: "sherpaonnx", runtime: .onnx,
            displayName: "GigaAM", description: "", sizeBytes: modelBytes + tokensBytes, languages: ["ru"],
            files: files, quantization: "int8", minChip: .m2, minRAMGB: 8, recommendedFor: []
        )
        let manifest = ModelManifestFile(
            schemaVersion: ModelManifestFile.supportedSchemaVersion, descriptor: descriptor
        )
        try DomainJSON.encode(manifest).write(to: manifestURL)
        // Сам манифест обязан разбираться — иначе тест проверял бы ветку «манифест не читается».
        _ = try DomainJSON.decode(ModelManifestFile.self, from: Data(contentsOf: manifestURL))
    }

    private func assertEngineError(
        _ expected: EngineError, _ request: TranscriptionRequest, engine: GigaAMEngine,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await run(request, engine: engine)
            XCTFail("ожидалась \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? EngineError, expected, file: file, line: line)
        }
    }
}

final class CountingFactory: GigaAMRecognizerFactory, @unchecked Sendable {
    private let recognizer: any GigaAMRecognizer
    private let lock = NSLock()
    private var made = 0

    init(recognizer: any GigaAMRecognizer) {
        self.recognizer = recognizer
    }

    var makeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return made
    }

    func makeRecognizer(modelDirectory: URL) throws -> any GigaAMRecognizer {
        lock.lock()
        made += 1
        lock.unlock()
        return recognizer
    }
}
