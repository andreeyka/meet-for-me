//  ModelCatalogManager — профили транскрибации и разрешение путей (C-014 v6 §3, «Поведение»;
//  инв. 8–10, 12, 13, 19).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Встроенные профили — из действующего `catalog.json`; пользовательские переопределяют
//  встроенные по `id` («Поведение»). Профиль называет модель только `id`, без версии:
//  годной считается НОВЕЙШАЯ по semver скачанная версия (`downloaded`/`loaded`); если
//  скачанной нет — в отказе и в `missingModels` стоит новейшая версия каталога.

import Foundation
import DomainCore

extension ModelCatalogManager {

    public func profiles() async -> [TranscriptionProfile] {
        effectiveProfiles()
    }

    public func saveProfile(_ profile: TranscriptionProfile) async throws {
        guard !profile.isBuiltIn else {
            throw ModelCatalogError.builtInProfileImmutable(id: profile.id)
        }
        guard catalog.models.contains(where: { $0.id == profile.asrModelId }) else {
            // MEE-458 п.2: версии здесь нет ни у кого — профиль называет модель только `id`
            // (C-014 §3), а в каталоге нет ни одной версии этого `id`. Пустая строка —
            // «версия не названа», не пропущенное значение; см. `unnamedVersion`.
            throw ModelCatalogError.unknownModel(id: profile.asrModelId, version: Self.unnamedVersion)
        }
        userProfiles[profile.id] = profile
        hub.yield(.profilesChanged)
    }

    public func deleteProfile(id: String) async throws {
        if userProfiles.removeValue(forKey: id) != nil {
            hub.yield(.profilesChanged)
            return
        }
        if catalog.profiles.contains(where: { $0.id == id }) {
            throw ModelCatalogError.builtInProfileImmutable(id: id)
        }
        throw ModelCatalogError.unknownProfile(id: id)
    }

    public func resolve(profileId: String) async throws -> ResolvedProfile {
        let profile = try profile(profileId)
        guard let asr = readyBundle(modelId: profile.asrModelId) else {
            let newest = newestCatalogDescriptor(modelId: profile.asrModelId)
            throw ModelCatalogError.notDownloaded(modelId: profile.asrModelId, version: newest?.version ?? "")
        }
        return ResolvedProfile(
            profileId: profile.id,
            language: profile.language,
            asr: asr,
            vad: profile.vadModelId.flatMap(readyBundle(modelId:)),
            diarization: profile.diarizationModelId.flatMap(readyBundle(modelId:)),
            embedding: profile.embeddingModelId.flatMap(readyBundle(modelId:)),
            diarizationParameters: profile.diarization)
    }

    public func missingModels(profileId: String) async throws -> [ModelDescriptor] {
        let profile = try profile(profileId)
        var missing: [ModelDescriptor] = []
        for modelId in Self.modelIds(of: profile) where readyBundle(modelId: modelId) == nil {
            guard let descriptor = newestCatalogDescriptor(modelId: modelId) else {
                // MEE-458 п.2: тот же случай — профиль без версии, каталог без этого `id`.
                throw ModelCatalogError.unknownModel(id: modelId, version: Self.unnamedVersion)
            }
            missing.append(descriptor)
        }
        return missing
    }

    // MARK: - Справки

    /// `version` в `unknownModel`, когда модель названа профилем (только `id`, C-014 §3) и в
    /// каталоге нет ни одной её версии: взять версию неоткуда. Контракт отдельного значения
    /// для этого случая не вводит — пустая строка, как и прежде, но названная.
    static let unnamedVersion = ""

    func effectiveProfiles() -> [TranscriptionProfile] {
        let builtIn = catalog.profiles.map { userProfiles[$0.id] ?? $0 }
        let builtInIds = Set(catalog.profiles.map(\.id))
        let userOnly = userProfiles.values
            .filter { !builtInIds.contains($0.id) }
            .sorted { $0.id < $1.id }
        return builtIn + userOnly
    }

    private func profile(_ id: String) throws -> TranscriptionProfile {
        guard let profile = effectiveProfiles().first(where: { $0.id == id }) else {
            throw ModelCatalogError.unknownProfile(id: id)
        }
        return profile
    }

    private func newestCatalogDescriptor(modelId: String) -> ModelDescriptor? {
        catalog.models
            .filter { $0.id == modelId }
            .max { ModelVersionOrder.isNewer($1.version, than: $0.version) }
    }

    /// Бандл новейшей скачанной версии модели; `nil` — ни одна версия не готова.
    private func readyBundle(modelId: String) -> ModelBundle? {
        let candidates = catalog.models
            .filter { $0.id == modelId }
            .sorted { ModelVersionOrder.isNewer($0.version, than: $1.version) }
        for descriptor in candidates {
            switch currentState(ModelKey(id: descriptor.id, version: descriptor.version)) {
            case .downloaded, .loaded:
                return ModelBundle(modelId: descriptor.id, version: descriptor.version, role: descriptor.role,
                                   runtime: descriptor.runtime, directoryURL: directory(for: descriptor))
            default:
                continue
            }
        }
        return nil
    }
}
