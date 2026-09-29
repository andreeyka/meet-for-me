//  ModelManager — реализация каталога моделей, `ModelCatalogPort` (C-014 v6, MEE-22; MEE-442).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Каталог принадлежит владельцу модуля: файлы здесь изменяет только он (П1).
//  Всё, что пересекает границу модуля, описано контрактом архитектора и меняется
//  только через interface-request (П2, П6). Границы и запреты — docs/module-map.md.
//
//  Публичная поверхность (инв. 32, `.github/scripts/allowed-types/ModelManager.json`) —
//  один собственный тип `ModelCatalogManager` (допуск (в)) и типы C-014 в его сигнатурах.
//  Шов сети (`ModelFileTransport`), шов машины (`MachineEnvironment`) и встроенный каталог
//  — `internal`: тесты берут их через `@testable import`, composition root — не видит.
//
//  Чего модуль не делает (инв. 7, module-map): не загружает модели в память и не исполняет
//  инференс — ведёт учёт и отдаёт пути.
//
//  Пользовательские профили (C-014 «Поведение») держатся в памяти процесса: хранилище
//  `app_settings` (C-016 §2.1) — порт `SettingsRepository`, которого нет среди типов,
//  допустимых на публичной границе таргета (инв. 32, допуск (а)). Раскрыто в PR MEE-442.

import Foundation
import DomainCore

/// Каталог моделей: `catalog.json`, файлы моделей на диске, загрузка с докачкой, профили.
public actor ModelCatalogManager: ModelCatalogPort {

    let layout: FileLayout
    let catalogURL: URL
    let transport: ModelFileTransport
    let environment: MachineEnvironment
    let hub = ModelEventHub()

    var catalog: ModelCatalogFile
    var userProfiles: [String: TranscriptionProfile] = [:]
    var sessions: [ModelKey: DownloadSession] = [:]
    var failures: [ModelKey: ModelCatalogError] = [:]
    var verified: [ModelKey: Verification] = [:]
    var useCounts: [ModelKey: Int] = [:]
    var tokens: [UUID: [ModelKey]] = [:]
    var published: [ModelKey: ModelState] = [:]

    /// `rootDirectory` — корень `FileLayout` (C-010 §1); модели лежат в `models/` под ним.
    /// `catalogURL` — адрес актуального `catalog.json` на CDN.
    public init(rootDirectory: URL, catalogURL: URL) {
        self.init(root: rootDirectory,
                  catalogURL: catalogURL,
                  transport: URLSessionModelFileTransport(),
                  environment: SystemMachineEnvironment(),
                  builtInCatalog: Self.builtInCatalogData())
    }

    init(root: URL,
         catalogURL: URL,
         transport: ModelFileTransport,
         environment: MachineEnvironment,
         builtInCatalog: Data?) {
        layout = FileLayout(root: root)
        self.catalogURL = catalogURL
        self.transport = transport
        self.environment = environment
        catalog = Self.initialCatalog(cacheURL: Self.cachedCatalogURL(root: root), builtIn: builtInCatalog)
    }

    // MARK: - Каталог

    public func refreshCatalog() async throws {
        let buffer = ByteAccumulator()
        let response: HTTPRangeResponse
        do {
            response = try await transport.fetch(url: catalogURL, firstByte: 0) { buffer.append($0) }
        } catch {
            throw ModelCatalogError.manifestUnreachable(message: "catalog.json: \(error)")
        }
        guard response.statusCode == 200 || (response.statusCode == 206 && (response.firstByte ?? 0) == 0) else {
            throw ModelCatalogError.manifestUnreachable(message: "catalog.json: HTTP \(response.statusCode)")
        }
        let bytes = buffer.data
        // Инв. 31: отвергнутый каталог действующий не заменяет — бросок до присваивания.
        let fresh = try CatalogReader.catalog(from: bytes)
        catalog = fresh
        storeCachedCatalog(bytes)
        hub.yield(.catalogRefreshed(modelCount: fresh.models.count))
        hub.yield(.profilesChanged)
    }

    public func models() async -> [ModelDescriptor] {
        catalog.models
    }

    public func model(id: String, version: String) async -> ModelDescriptor? {
        catalogDescriptor(ModelKey(id: id, version: version))
    }

    public nonisolated func events() -> AsyncStream<ModelCatalogEvent> {
        hub.stream()
    }

    // MARK: - Встроенная и сохранённая копии каталога

    /// Встроенная копия `catalog.json` из ресурсов таргета (C-014 §2; К1).
    static func builtInCatalogData() -> Data? {
        guard let url = Bundle.module.url(forResource: "catalog", withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    static func cachedCatalogURL(root: URL) -> URL {
        root.appendingPathComponent("models").appendingPathComponent("catalog.json")
    }

    /// Действующий каталог при старте: скачанный ранее, иначе встроенный, иначе пустой.
    static func initialCatalog(cacheURL: URL, builtIn: Data?) -> ModelCatalogFile {
        if let cached = try? Data(contentsOf: cacheURL), let file = try? CatalogReader.catalog(from: cached) {
            return file
        }
        if let builtIn, let file = try? CatalogReader.catalog(from: builtIn) {
            return file
        }
        return ModelCatalogFile(schemaVersion: ModelCatalogFile.supportedSchemaVersion,
                                generatedAt: Date(timeIntervalSince1970: 0), models: [], profiles: [])
    }

    /// Байты принятого каталога сохраняются как пришли — `catalog.json` приложение не пишет
    /// кодировщиком, только хранит полученную копию (инв. 14: «скачанный ранее»).
    private func storeCachedCatalog(_ bytes: Data) {
        let url = Self.cachedCatalogURL(root: layout.root)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? bytes.write(to: url, options: .atomic)
    }

    // MARK: - Общие справки

    func catalogDescriptor(_ key: ModelKey) -> ModelDescriptor? {
        catalog.models.first { $0.id == key.id && $0.version == key.version }
    }

    func directory(for descriptor: ModelDescriptor) -> URL {
        layout.modelDirectory(engine: descriptor.engine, modelId: descriptor.id, version: descriptor.version)
    }

    /// Публикует `stateChanged`, если состояние модели отличается от последнего опубликованного.
    func publish(_ key: ModelKey, _ state: ModelState) {
        guard published[key] != state else { return }
        published[key] = state
        hub.yield(.stateChanged(modelId: key.id, version: key.version, state: state))
    }
}
