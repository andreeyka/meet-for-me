//  Общая оснастка тестов model-manager: временный корень (`TemporaryFileLayout`, C-010),
//  синтетические модели с малыми файлами и настоящими `sha256`, сборка каталога через
//  `DomainJSON`, запись событий, чтение исходников модуля (мех.-проверки К6/К18/К36/К44).

import Foundation
import XCTest
import DomainCore
import DomainTestKit
@testable import ModelManager

/// Синтетическая модель: описание плюс байты её файлов на «CDN».
struct TestModel {
    let descriptor: ModelDescriptor
    let contents: [String: Data]

    func url(_ name: String) -> URL {
        descriptor.files.first { $0.name == name }?.url ?? URL(fileURLWithPath: "/nonexistent")
    }

    static func make(id: String,
                     version: String = "1.0.0",
                     role: ModelRole = .asr,
                     engine: String = "sherpaonnx",
                     minChip: MinChip = .m1,
                     minRAMGB: Int = 1,
                     files: [(String, Data)]) -> TestModel {
        let modelFiles = files.map { name, data in
            ModelFile(name: name,
                      url: URL(string: "https://cdn.test/\(id)/\(version)/\(name)") ?? URL(fileURLWithPath: "/"),
                      sha256: SHA256Digest.hex(of: data),
                      sizeBytes: Int64(data.count))
        }
        let descriptor = ModelDescriptor(
            id: id, version: version, role: role, engine: engine, runtime: .onnx,
            displayName: id, description: "синтетическая модель", sizeBytes: modelFiles.reduce(0) { $0 + $1.sizeBytes },
            languages: ["ru"], files: modelFiles, quantization: nil, minChip: minChip, minRAMGB: minRAMGB,
            recommendedFor: [])
        return TestModel(descriptor: descriptor, contents: Dictionary(uniqueKeysWithValues: files))
    }

    /// Пропорции GigaAM из §2 (226 МиБ + 10 МиБ), уменьшенные до байт: 226 Б и 10 Б.
    static func gigaamLike(id: String = "gigaam-test") -> TestModel {
        make(id: id, files: [("model.int8.onnx", bytes(226, seed: 1)), ("vocab.txt", bytes(10, seed: 2))])
    }

    static func bytes(_ count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }
}

func testProfile(id: String, asr: String, vad: String? = nil, diarization: String? = nil,
                 embedding: String? = nil, builtIn: Bool = true) -> TranscriptionProfile {
    TranscriptionProfile(
        id: id, displayName: id, language: "ru", asrModelId: asr, vadModelId: vad,
        diarizationModelId: diarization, embeddingModelId: embedding,
        diarization: DiarizationParameters(expectedSpeakers: nil, clusteringThreshold: 0.7, minSegmentMs: 500),
        isBuiltIn: builtIn)
}

/// Испытательный стенд: временный корень, тестовый транспорт, тестовая машина.
final class ModelHarness {
    static let catalogURL = URL(string: "https://cdn.test/catalog.json") ?? URL(fileURLWithPath: "/")

    let temporary = TemporaryFileLayout()
    let transport = FakeModelFileTransport()
    let machine = FakeMachine()
    var models: [TestModel]
    var profiles: [TranscriptionProfile]

    var root: URL { temporary.layout.root }

    init(models: [TestModel], profiles: [TranscriptionProfile] = []) {
        self.models = models
        self.profiles = profiles
        for model in models {
            for file in model.descriptor.files {
                transport.setContent(model.contents[file.name] ?? Data(), at: file.url)
            }
        }
    }

    var catalogFile: ModelCatalogFile {
        ModelCatalogFile(schemaVersion: 1, generatedAt: Date(timeIntervalSince1970: 1_790_000_000),
                         models: models.map(\.descriptor), profiles: profiles)
    }

    func catalogBytes() throws -> Data {
        try DomainJSON.encode(catalogFile)
    }

    /// Новый экземпляр над тем же диском (К35 — «перезапуск»).
    func makeManager(builtIn: Data? = nil) throws -> ModelCatalogManager {
        ModelCatalogManager(root: root, catalogURL: Self.catalogURL, transport: transport,
                            environment: machine, builtInCatalog: try builtIn ?? catalogBytes())
    }

    func directory(_ model: TestModel) -> URL {
        temporary.layout.modelDirectory(engine: model.descriptor.engine, modelId: model.descriptor.id,
                                        version: model.descriptor.version)
    }

    /// Кладёт файлы модели на диск в обход `download` (ручная установка, §5).
    func install(_ model: TestModel, replacing: [String: Data] = [:]) throws {
        let directory = directory(model)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, data) in model.contents {
            try (replacing[name] ?? data).write(to: directory.appendingPathComponent(name))
        }
    }

    func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// Суммарная длина всех файлов каталога модели — независимое от реализации наблюдение.
    func occupied(_ model: TestModel) -> Int64 {
        let directory = directory(model)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.reduce(0) { $0 + max(0, fileSize(directory.appendingPathComponent($1))) }
    }
}

/// Запись `ModelCatalogEvent` с подписки до конца теста.
final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [ModelCatalogEvent] = []
    private var task: Task<Void, Never>?

    init(_ stream: AsyncStream<ModelCatalogEvent>) {
        task = Task { [weak self] in
            for await event in stream {
                self?.append(event)
            }
        }
    }

    deinit {
        task?.cancel()
    }

    private func append(_ event: ModelCatalogEvent) {
        lock.lock()
        received.append(event)
        lock.unlock()
    }

    var events: [ModelCatalogEvent] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    /// Ждёт доставки событий подписчику (поток асинхронный): до `timeout` или до условия,
    /// затем ещё короткую паузу, чтобы лишнее событие, если оно есть, тоже успело прийти.
    func settle(until condition: ([ModelCatalogEvent]) -> Bool = { _ in true }, timeout: Double = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(events), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    func states(of id: String) -> [ModelState] {
        events.compactMap { event in
            guard case .stateChanged(let modelId, _, let state) = event, modelId == id else { return nil }
            return state
        }
    }
}

/// Исходники таргета `ModelManager` — чтение через `#filePath` (образец `EngineKitSourceSurfaceTests`).
enum ModelManagerSources {
    static func files() throws -> [(name: String, text: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ModelManager")
        var result: [(name: String, text: String)] = []
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            result.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        return result
    }

    /// Код без строк-комментариев: шапки файлов называют запрещённые имена, объясняя запрет.
    static func code(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

extension ModelState {
    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}
