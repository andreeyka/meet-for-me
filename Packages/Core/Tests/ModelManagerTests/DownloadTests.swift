//  К15–К17, К20, К50 перечня MEE-429 (план MEE-436, группы Г/Д/Н): раскладка на диске,
//  ручная установка, успех и несовпадение `sha256`, форма заголовка `Range`, момент записи
//  `.manifest.json`. Без сети: файлы отдаёт тестовый `ModelFileTransport`.

import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DomainCore
import DomainTestKit
@testable import ModelManager

/// Изменяемое значение для наблюдений изнутри `@Sendable`-замыканий тестового транспорта.
final class Probe<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func update(_ change: (inout Value) -> Void) {
        lock.lock()
        change(&stored)
        lock.unlock()
    }
}

final class DownloadTests: XCTestCase {

    func expectError(_ expected: ModelCatalogError, file: StaticString = #filePath, line: UInt = #line,
                     _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("ожидался \(expected)", file: file, line: line)
        } catch let error as ModelCatalogError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("ожидался \(expected), получено \(error)", file: file, line: line)
        }
    }

    // MARK: - Г. Раскладка и ручная установка

    func test_k15_modelFilesLaidOutByEngineIdAndVersion() async throws {
        let model = TestModel.make(id: "layout-asr", version: "2.1.0", engine: "sherpaonnx",
                                   files: [("encoder.onnx", TestModel.bytes(40, seed: 7)),
                                           ("tokens.txt", TestModel.bytes(12, seed: 8))])
        let harness = ModelHarness(models: [model])
        let manager = try harness.makeManager()
        try await manager.download(id: "layout-asr", version: "2.1.0")

        let expected = harness.root.appendingPathComponent("models/sherpaonnx/layout-asr@2.1.0")
        XCTAssertEqual(harness.directory(model).standardizedFileURL, expected.standardizedFileURL)
        let names = try FileManager.default.contentsOfDirectory(atPath: expected.path).sorted()
        XCTAssertEqual(names, [".manifest.json", "encoder.onnx", "tokens.txt"], "имена дословно, подкаталогов нет")
        for name in names {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: expected.appendingPathComponent(name).path,
                                                         isDirectory: &isDirectory))
            XCTAssertFalse(isDirectory.boolValue, "\(name) — не каталог")
        }
    }

    func test_k16_manuallyInstalledFilesVerifiedBySha256OnStartup() async throws {
        let good = TestModel.make(id: "manual-good", files: [("g.bin", TestModel.bytes(33, seed: 9))])
        let bad = TestModel.make(id: "manual-bad", files: [("b.bin", TestModel.bytes(33, seed: 10))])
        let harness = ModelHarness(models: [good, bad])
        try harness.install(good)
        try harness.install(bad, replacing: ["b.bin": TestModel.bytes(33, seed: 99)])
        XCTAssertFalse(harness.exists(harness.directory(good).appendingPathComponent(".manifest.json")),
                       "вектор: ручная установка — без .manifest.json")

        let manager = try harness.makeManager()
        let goodState = await manager.state(id: "manual-good", version: "1.0.0")
        XCTAssertEqual(goodState, .downloaded)
        let badState = await manager.state(id: "manual-bad", version: "1.0.0")
        guard case .error(.checksumMismatch(let name, let expected, _)) = badState else {
            return XCTFail("ожидалось error(checksumMismatch), получено \(badState)")
        }
        XCTAssertEqual(name, "b.bin")
        XCTAssertEqual(expected, bad.descriptor.files[0].sha256)
        XCTAssertTrue(harness.transport.requests.isEmpty, "сверка — без сети")
    }

    // MARK: - Д. Успех и несовпадение sha256

    func test_k17_downloadSucceedsAndChecksumMismatchRemovesBothFiles() async throws {
        let model = TestModel.gigaamLike()
        let harness = ModelHarness(models: [model])
        let manager = try harness.makeManager()
        try await manager.download(id: model.descriptor.id, version: model.descriptor.version)
        for file in model.descriptor.files {
            let url = harness.directory(model).appendingPathComponent(file.name)
            XCTAssertEqual(harness.fileSize(url), file.sizeBytes, "длина \(file.name) — files[].sizeBytes")
            XCTAssertEqual(try SHA256Digest.hex(ofFileAt: url), file.sha256, "sha256 \(file.name)")
            XCTAssertFalse(harness.exists(url.appendingPathExtension("part")))
        }
        let state = await manager.state(id: model.descriptor.id, version: model.descriptor.version)
        XCTAssertEqual(state, .downloaded)

        // Второй вектор: sha256 второго файла не сходится.
        let broken = TestModel.gigaamLike(id: "gigaam-broken")
        let second = ModelHarness(models: [broken])
        second.transport.setContent(TestModel.bytes(10, seed: 77), at: broken.url("vocab.txt"))
        let brokenManager = try second.makeManager()
        do {
            try await brokenManager.download(id: broken.descriptor.id, version: broken.descriptor.version)
            XCTFail("ожидался checksumMismatch")
        } catch ModelCatalogError.checksumMismatch(let name, _, _) {
            XCTAssertEqual(name, "vocab.txt")
        }
        XCTAssertFalse(second.exists(second.directory(broken)), "удалены оба файла модели и .part")
        let brokenState = await brokenManager.state(id: broken.descriptor.id, version: broken.descriptor.version)
        guard case .error(.checksumMismatch) = brokenState else {
            return XCTFail("ожидалось error(checksumMismatch), получено \(brokenState)")
        }
    }

    func test_k20_rangeHeaderFormExactByteOffset() throws {
        XCTAssertEqual(ModelFileRequest.rangeHeaderLine(firstByte: 1024), "Range: bytes=1024-")
        XCTAssertNil(ModelFileRequest.rangeHeaderLine(firstByte: 0), "с нуля — без заголовка")
        let url = try XCTUnwrap(URL(string: "https://cdn.test/file"))
        let request = ModelFileRequest.request(url: url, firstByte: 1024)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=1024-")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(ModelFileRequest.request(url: url, firstByte: 0).value(forHTTPHeaderField: "Range"))
    }

    // MARK: - Н. Момент записи .manifest.json

    func test_k50_manifestJsonAbsentDuringLastFileReceiveWrittenOnlyAfterAllChecksumsVerified() async throws {
        let model = TestModel.gigaamLike()
        let harness = ModelHarness(models: [model])
        let manifestURL = harness.directory(model).appendingPathComponent(".manifest.json")
        let lastURL = model.url("vocab.txt")
        let seen = Probe<[Bool]>([])
        harness.transport.onChunk { url, _ in
            guard url == lastURL else { return }
            let exists = FileManager.default.fileExists(atPath: manifestURL.path)
            seen.update { $0.append(exists) }
        }
        let manager = try harness.makeManager()
        try await manager.download(id: model.descriptor.id, version: model.descriptor.version)
        XCTAssertFalse(seen.value.isEmpty, "вектор непустоты: наблюдение изнутри receive последнего файла было")
        XCTAssertEqual(Set(seen.value), [false], "во время приёма последнего файла .manifest.json ещё нет")
        XCTAssertTrue(harness.exists(manifestURL), "после сверки всех sha256 — записан")
        try await assertManifestNotRewritten(manifestURL, harness: harness, model: model, manager: manager)

        // Вход В: sha256 одного из файлов не сошёлся — .manifest.json нет.
        let broken = TestModel.gigaamLike(id: "gigaam-bad-manifest")
        let second = ModelHarness(models: [broken])
        second.transport.setContent(TestModel.bytes(226, seed: 55), at: broken.url("model.int8.onnx"))
        let brokenManager = try second.makeManager()
        await expectError(.checksumMismatch(fileName: "model.int8.onnx",
                                            expected: broken.descriptor.files[0].sha256,
                                            actual: SHA256Digest.hex(of: TestModel.bytes(226, seed: 55)))) {
            try await brokenManager.download(id: broken.descriptor.id, version: broken.descriptor.version)
        }
        XCTAssertFalse(second.exists(second.directory(broken).appendingPathComponent(".manifest.json")))
    }

    /// «Один раз» (§2.1): последующие вопросы о состоянии, в том числе новым экземпляром, файл
    /// не переписывают — номер файла на томе и байты те же (запись атомарная: новый файл — новый номер).
    private func assertManifestNotRewritten(_ url: URL, harness: ModelHarness, model: TestModel,
                                            manager: ModelCatalogManager) async throws {
        func identity() throws -> (number: Int, bytes: Data) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return ((attributes[.systemFileNumber] as? NSNumber)?.intValue ?? -1, try Data(contentsOf: url))
        }
        let before = try identity()
        XCTAssertNotEqual(before.number, -1, "вектор: номер файла читается")
        _ = await manager.state(id: model.descriptor.id, version: model.descriptor.version)
        _ = await manager.diskUsage()
        let restarted = try harness.makeManager()
        let restartedState = await restarted.state(id: model.descriptor.id, version: model.descriptor.version)
        XCTAssertEqual(restartedState, .downloaded)
        let after = try identity()
        XCTAssertEqual(after.number, before.number, ".manifest.json не переписан")
        XCTAssertEqual(after.bytes, before.bytes)
    }
}
