//  FakeModelCatalogPort — реализация `ModelCatalogPort` в памяти, C-014 v6
//  §«Фейк для тестов», дословно: без сети и без файлов (кроме `resolve`, ниже); тест задаёт
//  набор `ModelDescriptor`/`TranscriptionProfile`, состояние каждой модели (включая
//  `paused(bytesOnDisk:)`), какая ошибка вылетит из `download`/`resolve`/`delete`/`beginUse`,
//  и вручную проталкивает `ModelCatalogEvent`. Расписки ведутся честным счётчиком —
//  `beginUseSuccessCount`/`endUseCallCount`/`endUseEffectiveCount` — тест вправе проверить,
//  что потребитель погасил ровно столько, сколько взял (§«Фейк для тестов»).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  `CatalogFixtures` и фейк `ModelFileTransport` сюда НЕ входят (MEE-395, «Не в этой
//  задаче»): первый не назван «Готовностью» этой задачи, второй контракт прямо селит в
//  `Packages/Core/Tests/ModelManagerTests/` через `@testable import`, не в `DomainTestKit`.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА (тот же довод и та же форма, что у `FakeCalendarPort`,
//  `FakeProcessMonitorPort`, `FakePowerPort`) — отсюда следствия, названные прямо:
//
//  1. `loaded` НЕ ЯВЛЯЕТСЯ базовым состоянием, которое можно задать `setState`: §4.1
//     определяет его счётчиком невозвращённых расписок («beginUse поднимает счётчик,
//     endUse опускает; счётчик больше нуля — loaded»), и фейк воспроизводит ровно это —
//     `state(id:version:)` отдаёт `.loaded`, когда есть хоть одна непогашенная расписка на
//     модель, независимо от заданного `setState`. Хочет тест увидеть `.loaded` — модель
//     должна быть `.downloaded` и пройти через настоящий `beginUse`.
//  2. `resolve(profileId:)` находит бандл модели ролью `TranscriptionProfile.<role>ModelId`
//     ПЕРВЫМ совпадением по `id` среди заданных `setCatalog` дескрипторов, не «последней
//     версией» и не «единственной»: контракт не даёт профилю версии модели (только `id`),
//     и выбор версии — не предмет порта (это `model-manager`, вне задачи). Тест, которому
//     нужна конкретная версия, регистрирует ровно одну версию этого `id`.
//  3. `download`/`verify` не проверяют `sha256` и не пишут байт на диск: `sizeBytes` в
//     `diskUsage()`/`downloading(fraction:)`/`paused(bytesOnDisk:)` фейк держит внутренне
//     согласованными по §4.2 сам с собой, а не сверяет с содержимым `ModelDescriptor.files`.
//     Единственное место, где фейк касается диска, — `resolve` (инвариант 19, ниже).
//
//  `resolve` — единственный метод, трогающий диск: он создаёт `directoryURL` и пустые файлы
//  по именам `ModelDescriptor.files` внутри временного каталога `DomainTestKit
//  .TemporaryFileLayout` (C-010), чтобы бандл, который получает потребитель, был проверяем
//  по инварианту 19 («каталог существует и содержит все файлы модели в момент выдачи»),
//  а не только по значению. Путь стабилен между вызовами: `FileLayout.modelDirectory
//  (engine:modelId:version:)` — чистая функция от `(engine, modelId, version)`.
//
//  `@unchecked Sendable` с замком, а не актор — тот же довод, что у `FakeCalendarPort`:
//  `ModelCatalogPort` объявлен `: Sendable`, а `events()` синхронен, актором протокол
//  не покрыть.
//
//  Настройка тестом и счётчик расписок — во втором файле того же класса, `extension`
//  (`FakeModelCatalogPort+Configuration.swift`): тело класса выросло за порог
//  `type_body_length` SwiftLint (250 строк без учёта комментариев и пустых) после
//  возврата РП на #122 (инварианты 8/9). Стораж поэтому не `private` — его зовёт и
//  второй файл.

import Foundation
import DomainCore

/// Адрес одной версии модели — `ModelDescriptor`/`ModelState` фейк держит по этому ключу,
/// как и сам порт адресует их парой `(id, version)`.
struct ModelKey: Hashable {
    let id: String
    let version: String
}

public final class FakeModelCatalogPort: ModelCatalogPort, @unchecked Sendable {

    private let lock = NSLock()
    private let temporaryLayout = TemporaryFileLayout()

    var descriptorsByKey: [ModelKey: ModelDescriptor] = [:]
    var statesByKey: [ModelKey: ModelState] = [:]
    var profilesById: [String: TranscriptionProfile] = [:]

    /// Модели, занятые непогашенными расписками, по ключу выданного `beginUse` — счётчик,
    /// а не множество: одна модель может входить в несколько разом невозвращённых расписок.
    private var useCountsByKey: [ModelKey: Int] = [:]
    var outstandingTokens: [ModelUseToken: [ModelKey]] = [:]

    var downloadFailures: [ModelKey: ModelCatalogError] = [:]
    var deleteFailures: [ModelKey: ModelCatalogError] = [:]
    var resolveFailures: [String: ModelCatalogError] = [:]

    /// Отказ `beginUse`, не привязанный к конкретному набору бандлов — контракт уже даёт
    /// естественный отказ `notDownloaded` по состоянию (инвариант 22); это — способ
    /// проверить любой ДРУГОЙ отказ на границе. `nil` снимает его, тем же приёмом, что
    /// `failSync(with:for:)` у `FakeCalendarPort`.
    public var forcedBeginUseError: ModelCatalogError?

    var eventContinuations: [AsyncStream<ModelCatalogEvent>.Continuation] = []

    var beginUseSuccesses = 0
    var endUseCalls = 0
    var endUseEffective = 0

    public init() {}

    func locked<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: - ModelCatalogPort

    public func refreshCatalog() async throws {
        let count = locked { descriptorsByKey.count }
        pushEvent(.catalogRefreshed(modelCount: count))
    }

    public func models() async -> [ModelDescriptor] {
        locked { descriptorsByKey.values }
            .sorted { $0.id == $1.id ? $0.version < $1.version : $0.id < $1.id }
    }

    public func model(id: String, version: String) async -> ModelDescriptor? {
        locked { descriptorsByKey[ModelKey(id: id, version: version)] }
    }

    public func state(id: String, version: String) async -> ModelState {
        locked { computedState(for: ModelKey(id: id, version: version)) }
    }

    public func download(id: String, version: String) async throws {
        let key = ModelKey(id: id, version: version)
        if let error = locked({ downloadFailures[key] }) { throw error }
        locked { statesByKey[key] = .downloaded }
        pushEvent(.stateChanged(modelId: id, version: version, state: .downloaded))
    }

    public func cancelDownload(id: String, version: String) async {
        let key = ModelKey(id: id, version: version)
        let paused = locked { () -> ModelState in
            let bytesOnDisk = bytesOnDiskLocked(for: key)
            let state = ModelState.paused(bytesOnDisk: bytesOnDisk)
            statesByKey[key] = state
            return state
        }
        pushEvent(.stateChanged(modelId: id, version: version, state: paused))
    }

    /// Не проверяет `sha256` (заголовок, п. 3) — не бросает никогда.
    public func verify(id: String, version: String) async throws {}

    public func delete(id: String, version: String) async throws {
        let key = ModelKey(id: id, version: version)
        if let error = locked({ deleteFailures[key] }) { throw error }
        locked {
            statesByKey[key] = .available
            useCountsByKey[key] = nil
        }
        pushEvent(.stateChanged(modelId: id, version: version, state: .available))
    }

    public func diskUsage() async -> [ModelDiskUsage] {
        locked {
            let keys = Set(statesByKey.keys).union(descriptorsByKey.keys)
            return keys.compactMap { key -> ModelDiskUsage? in
                guard let bytes = occupiedBytesLocked(for: key) else { return nil }
                return ModelDiskUsage(modelId: key.id, version: key.version, bytesOnDisk: bytes)
            }
            .sorted { $0.modelId == $1.modelId ? $0.version < $1.version : $0.modelId < $1.modelId }
        }
    }

    /// Инвариант 22: атомарна — валидирует ВСЕ бандлы прежде чем пометить хоть один.
    public func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken {
        if let error = locked({ forcedBeginUseError }) { throw error }
        let keys = bundles.map { ModelKey(id: $0.modelId, version: $0.version) }
        return try locked {
            for key in keys {
                switch computedState(for: key) {
                case .downloaded, .loaded: continue
                default: throw ModelCatalogError.notDownloaded(modelId: key.id, version: key.version)
                }
            }
            let token = ModelUseToken(rawValue: UUID())
            outstandingTokens[token] = keys
            for key in keys { useCountsByKey[key, default: 0] += 1 }
            beginUseSuccesses += 1
            return token
        }
    }

    /// Инвариант 23: идемпотентна — повторное погашение и погашение неизвестной расписки
    /// не эффект, только звонок (`endUseCallCount` растёт, `endUseEffectiveCount` — нет).
    public func endUse(_ token: ModelUseToken) async {
        locked {
            endUseCalls += 1
            guard let keys = outstandingTokens.removeValue(forKey: token) else { return }
            for key in keys { useCountsByKey[key, default: 0] -= 1 }
            endUseEffective += 1
        }
    }

    public func profiles() async -> [TranscriptionProfile] {
        locked { profilesById.values }.sorted { $0.id < $1.id }
    }

    /// Инвариант 13, дословно: `asrModelId`, которого нет в каталоге, — отказ, профиль не
    /// сохраняется. Поиск по `id` без версии — тем же приёмом, что `resolve` (шапка, п. 2):
    /// профиль версии модели не несёт, сверять её здесь не с чем. Только `asrModelId` —
    /// инвариант 13 называет его один; необязательные роли инвариантом не покрыты (инв. 9:
    /// «нет в каталоге» для них не ошибка ни на `resolve`, ни здесь).
    public func saveProfile(_ profile: TranscriptionProfile) async throws {
        let known = locked { descriptorsByKey.keys.contains { $0.id == profile.asrModelId } }
        guard known else {
            throw ModelCatalogError.unknownModel(id: profile.asrModelId, version: "")
        }
        locked { profilesById[profile.id] = profile }
        pushEvent(.profilesChanged)
    }

    /// Погашение неизвестного `id` — без эффекта, тем же правилом, что `endUse` (инвариант 23).
    public func deleteProfile(id: String) async throws {
        let existed = locked { profilesById.removeValue(forKey: id) != nil }
        if existed { pushEvent(.profilesChanged) }
    }

    /// Инварианты 8, 9, 19 — дословно. Возврат РП на #122: первая редакция материализовала
    /// бандлы независимо от состояния модели, нарушая оба инварианта разом (`asr` проходил
    /// на `.available`, необязательные роли заполнялись всегда).
    public func resolve(profileId: String) async throws -> ResolvedProfile {
        if let error = locked({ resolveFailures[profileId] }) { throw error }
        guard let profile = locked({ profilesById[profileId] }) else {
            throw ModelCatalogError.unknownProfile(id: profileId)
        }
        let asr = try requiredBundle(forModelId: profile.asrModelId)
        let vad = try profile.vadModelId.flatMap(optionalBundle(forModelId:))
        let diarization = try profile.diarizationModelId.flatMap(optionalBundle(forModelId:))
        let embedding = try profile.embeddingModelId.flatMap(optionalBundle(forModelId:))
        return ResolvedProfile(
            profileId: profileId,
            language: profile.language,
            asr: asr,
            vad: vad,
            diarization: diarization,
            embedding: embedding,
            diarizationParameters: profile.diarization
        )
    }

    public func missingModels(profileId: String) async throws -> [ModelDescriptor] {
        guard let profile = locked({ profilesById[profileId] }) else {
            throw ModelCatalogError.unknownProfile(id: profileId)
        }
        let requiredIds = [profile.asrModelId, profile.vadModelId, profile.diarizationModelId, profile.embeddingModelId]
            .compactMap { $0 }
        return locked {
            requiredIds.compactMap { modelId -> ModelDescriptor? in
                guard let (key, descriptor) = descriptorsByKey.first(where: { $0.key.id == modelId }) else {
                    return nil
                }
                switch computedState(for: key) {
                case .downloaded, .loaded: return nil
                default: return descriptor
                }
            }
        }
    }

    public func events() -> AsyncStream<ModelCatalogEvent> {
        AsyncStream { continuation in
            locked { eventContinuations.append(continuation) }
        }
    }

    // MARK: - Общее (вызывать только под замком)

    private func computedState(for key: ModelKey) -> ModelState {
        if (useCountsByKey[key] ?? 0) > 0 { return .loaded }
        return statesByKey[key] ?? .available
    }

    /// §4.2: одна и та же величина проведена через `downloading(fraction:)` и
    /// `paused(bytesOnDisk:)` — `cancelDownload` строит второе из первого этой же формулой.
    private func bytesOnDiskLocked(for key: ModelKey) -> Int64 {
        guard case .downloading(let fraction) = statesByKey[key] else { return 0 }
        let sizeBytes = descriptorsByKey[key]?.sizeBytes ?? 0
        return Int64(fraction * Double(sizeBytes))
    }

    private func occupiedBytesLocked(for key: ModelKey) -> Int64? {
        switch computedState(for: key) {
        case .downloading(let fraction):
            return Int64(fraction * Double(descriptorsByKey[key]?.sizeBytes ?? 0))
        case .paused(let bytesOnDisk):
            return bytesOnDisk
        case .downloaded, .loaded:
            return descriptorsByKey[key]?.sizeBytes ?? 0
        case .available, .error:
            return nil
        }
    }

    /// Инвариант 8: `asr` — единственная роль, для которой неготовность отказывает всему
    /// `resolve`, а не даёт `nil`.
    private func requiredBundle(forModelId modelId: String) throws -> ModelBundle {
        let found = try locked { () throws -> (ModelKey, ModelDescriptor) in
            guard let match = descriptorsByKey.first(where: { $0.key.id == modelId }) else {
                throw ModelCatalogError.unknownModel(id: modelId, version: "")
            }
            switch computedState(for: match.key) {
            case .downloaded, .loaded: return match
            default: throw ModelCatalogError.notDownloaded(modelId: match.key.id, version: match.key.version)
            }
        }
        return try materializeBundle(key: found.0, descriptor: found.1)
    }

    /// Инвариант 9 дословно: `nil` при любой причине неготовности — неизвестная модель или
    /// известная, но не скачанная, — контракт не отделяет один случай от другого и
    /// прямо называет это «не ошибкой».
    private func optionalBundle(forModelId modelId: String) throws -> ModelBundle? {
        let found = locked { () -> (ModelKey, ModelDescriptor)? in
            guard let match = descriptorsByKey.first(where: { $0.key.id == modelId }) else { return nil }
            switch computedState(for: match.key) {
            case .downloaded, .loaded: return match
            default: return nil
            }
        }
        guard let (key, descriptor) = found else { return nil }
        return try materializeBundle(key: key, descriptor: descriptor)
    }

    /// Инвариант 19: материализует `directoryURL` и все файлы `ModelDescriptor.files`
    /// внутри `TemporaryFileLayout` перед тем, как отдать `ModelBundle`.
    private func materializeBundle(key: ModelKey, descriptor: ModelDescriptor) throws -> ModelBundle {
        let directoryURL = temporaryLayout.layout.modelDirectory(
            engine: descriptor.engine, modelId: key.id, version: key.version
        )
        try materialize(descriptor: descriptor, at: directoryURL)
        return ModelBundle(
            modelId: key.id, version: key.version, role: descriptor.role,
            runtime: descriptor.runtime, directoryURL: directoryURL
        )
    }

    private func materialize(descriptor: ModelDescriptor, at directoryURL: URL) throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        for file in descriptor.files {
            let fileURL = directoryURL.appendingPathComponent(file.name)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: Data())
            }
        }
    }
}
