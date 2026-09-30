//  GigaAMEngineModelFileTests — MEE-504 (Z6), замечание ревью (а): файл модели, чья длина не
//  совпала с `files[].sizeBytes` `.manifest.json`, — `modelMissing` ДО фабрики распознавателя (иначе
//  onnxruntime на обрезанном `.onnx` завершает процесс сервиса `std::terminate`).
//  MEE-513 (IR-157, критерии 5 и 6): нет `.manifest.json`, он не читается или в нём нет записи о файле —
//  тоже `modelMissing` до фабрики; причина — строкой в журнал `log`, не в `EngineError`.

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

    func testWithoutManifestOrWithUnreadableManifestIsModelMissingBeforeFactory() async throws {
        source.durations[recordingId] = 3_000
        try FileManager.default.removeItem(at: manifestURL)
        await assertEngineError(expected, try request([try audioRef(.system)]), engine: engine)
        for broken in ["{", "{}", "[]", ""] {
            try Data(broken.utf8).write(to: manifestURL)
            await assertEngineError(expected, try request([try audioRef(.system)]), engine: engine)
        }
        XCTAssertEqual(factory.makeCount, 0)
        XCTAssertEqual(source.requestCount, 0)
    }

    func testManifestWithoutEntryForModelFileIsModelMissing() async throws {
        source.durations[recordingId] = 3_000
        try writeManifest(modelBytes: 1, tokensBytes: 1, names: ["other.onnx", GigaAMEngine.tokensFileName])
        await assertEngineError(expected, try request([try audioRef(.system)]), engine: engine)
        XCTAssertEqual(factory.makeCount, 0)
    }

    // Критерий 6: подробности — в журнал, в ошибку только modelId и version
    func testReasonGoesToLogNotToError() async throws {
        source.durations[recordingId] = 3_000
        try writeManifest(modelBytes: 319_869_121, tokensBytes: 1)
        await assertEngineError(expected, try request([try audioRef(.system)]), engine: engine)
        try FileManager.default.removeItem(at: manifestURL)
        await assertEngineError(expected, try request([try audioRef(.system)]), engine: engine)
        let lines = engineLog.lines
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains(GigaAMEngine.modelFileName), lines[0])
        XCTAssertTrue(lines[0].contains("319869121"), lines[0])
        XCTAssertTrue(lines[0].contains("найдено 1"), lines[0])
        XCTAssertTrue(lines[1].contains(GigaAMEngine.manifestFileName), lines[1])
        for line in lines {
            XCTAssertTrue(line.contains("gigaam-v3-e2e-ctc-int8") && line.contains("3.0.0"), line)
        }
    }

    func testCompleteDirectoryDoesNotLog() async throws {
        source.durations[recordingId] = 3_000
        _ = try await run(try request([try audioRef(.system)]), engine: engine)
        XCTAssertEqual(engineLog.lines, [])
    }

    // MARK: - Опоры

    private lazy var factory = CountingFactory(recognizer: recognizer)
    private lazy var engine = makeEngine(factory: factory)

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
