//  ModelManager — реализация каталога моделей, `ModelCatalogPort` (C-014 v7, MEE-22; MEE-442, MEE-459).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Каталог принадлежит владельцу модуля: файлы здесь изменяет только он (П1).
//  Всё, что пересекает границу модуля, описано контрактом архитектора и меняется
//  только через interface-request (П2, П6). Границы и запреты — docs/module-map.md.
//
//  Публичная поверхность (инв. 32, `.github/scripts/allowed-types/ModelManager.json`) —
//  один собственный тип `ModelCatalogManager` (допуск (в)), типы C-014 в его сигнатурах и
//  `SettingsRepository` в `init` (допуск (г), v7). Шов сети (`ModelFileTransport`), шов
//  машины (`MachineEnvironment`) и встроенный каталог — `internal`: тесты берут их через
//  `@testable import`, composition root — не видит.
//
//  Чего модуль не делает (инв. 7, module-map): не загружает модели в память и не исполняет
//  инференс — ведёт учёт и отдаёт пути.
//
//  Пользовательские профили (инв. 37, v7) — одной строкой `app_settings` под ключом
//  `modelCatalog.userProfiles` через `SettingsRepository`; см. `+Profiles`/`+UserProfiles`.

import Foundation
import DomainCore

/// Каталог моделей: `catalog.json`, файлы моделей на диске, загрузка с докачкой, профили.
public actor ModelCatalogManager: ModelCatalogPort {

    let layout: FileLayout
    let catalogURL: URL
    let transport: ModelFileTransport
    let environment: MachineEnvironment
    let settings: SettingsRepository
    let log: @Sendable (String) -> Void
    let hub = ModelEventHub()

    var catalog: ModelCatalogFile
    /// Прочитанные пользовательские профили (инв. 37); `nil` — строка ещё не прочитана
    /// либо не читается: тогда её читают заново при следующем обращении.
    var userProfiles: [String: TranscriptionProfile]?
    var profileWriteHeld = false
    var profileWriteWaiters: [CheckedContinuation<Void, Never>] = []
    var sessions: [ModelKey: DownloadSession] = [:]
    var runningDownloads: [ModelKey: Task<Void, Error>] = [:]
    var failures: [ModelKey: ModelCatalogError] = [:]
    var verified: [ModelKey: Verification] = [:]
    var useCounts: [ModelKey: Int] = [:]
    var tokens: [UUID: [ModelKey]] = [:]
    var published: [ModelKey: ModelState] = [:]

    /// `rootDirectory` — корень `FileLayout` (C-010 §1); модели лежат в `models/` под ним.
    /// `catalogURL` — адрес актуального `catalog.json` на CDN. `settings` — тот же
    /// `SettingsRepository`, что у фасада C-016: в нём строка пользовательских профилей (инв. 37).
    public init(rootDirectory: URL, catalogURL: URL, settings: SettingsRepository) {
        self.init(root: rootDirectory,
                  catalogURL: catalogURL,
                  settings: settings,
                  transport: URLSessionModelFileTransport(),
                  environment: SystemMachineEnvironment(),
                  builtInCatalog: Self.builtInCatalogData())
    }

    init(root: URL,
         catalogURL: URL,
         settings: SettingsRepository,
         transport: ModelFileTransport,
         environment: MachineEnvironment,
         builtInCatalog: Data?,
         log: @escaping @Sendable (String) -> Void = ModelCatalogManager.standardErrorLog) {
        layout = FileLayout(root: root)
        self.catalogURL = catalogURL
        self.settings = settings
        self.transport = transport
        self.environment = environment
        self.log = log
        catalog = Self.initialCatalog(cacheURL: Self.cachedCatalogURL(root: root), builtIn: builtInCatalog, log: log)
    }

    // MARK: - Каталог

    public func refreshCatalog() async throws {
        let buffer = ByteAccumulator()
        do {
            try await transport.fetch(url: catalogURL, firstByte: 0, head: { response in
                // §6 (v7): статус до тела — отказ сервера не читает тело вовсе.
                guard response.statusCode == 200 || (response.statusCode == 206 && (response.firstByte ?? 0) == 0)
                else {
                    throw ModelCatalogError.manifestUnreachable(message: "catalog.json: HTTP \(response.statusCode)")
                }
            }, receive: { buffer.append($0) })
        } catch let error as ModelCatalogError {
            throw error
        } catch {
            throw ModelCatalogError.manifestUnreachable(message: "catalog.json: \(error)")
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

    /// Действующий каталог при старте (инв. 28, v7): из сохранённой копии и встроенного тот,
    /// чей `generatedAt` позже; при равенстве — копия. Копия, которая не читается или не
    /// проходит инварианты чтения (2, 3, 15, 30, 34), не выбирается — и это пишется в лог.
    /// Ни одного годного — пустой каталог.
    static func initialCatalog(cacheURL: URL, builtIn: Data?,
                               log: @Sendable (String) -> Void) -> ModelCatalogFile {
        let cached = readStartupCatalog(try? Data(contentsOf: cacheURL), name: "сохранённая копия", log: log)
        let bundled = readStartupCatalog(builtIn, name: "встроенный каталог", log: log)
        switch (cached, bundled) {
        case let (cached?, bundled?):
            return cached.generatedAt >= bundled.generatedAt ? cached : bundled
        case let (cached?, nil):
            return cached
        case let (nil, bundled?):
            return bundled
        case (nil, nil):
            return ModelCatalogFile(schemaVersion: ModelCatalogFile.supportedSchemaVersion,
                                    generatedAt: Date(timeIntervalSince1970: 0), models: [], profiles: [])
        }
    }

    private static func readStartupCatalog(_ data: Data?, name: String,
                                           log: @Sendable (String) -> Void) -> ModelCatalogFile? {
        guard let data else { return nil }
        do {
            return try CatalogReader.catalog(from: data)
        } catch {
            log("model-manager: \(name) catalog.json отвергнут при старте: \(asCatalogError(error))")
            return nil
        }
    }

    /// Лог по умолчанию — stderr: у `Packages/Core` общего журнала нет, а `os.Logger` в
    /// `ModelManager` запрещён инв. 20 (сборка на Linux).
    static let standardErrorLog: @Sendable (String) -> Void = { message in
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Байты принятого каталога сохраняются дословно, как пришли, и только после приёма —
    /// в `models/catalog.json` атомарной заменой (инв. 28, v7): перекодирование `DomainJSON`
    /// потеряло бы неизвестные ключи (§2.2).
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
