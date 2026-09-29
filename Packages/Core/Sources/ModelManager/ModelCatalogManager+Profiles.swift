//  ModelCatalogManager — профили транскрибации и разрешение путей (C-014 v7 §3, «Поведение»;
//  инв. 8–10, 12, 13, 19, 34, 35, 37).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  Встроенные профили — из действующего `catalog.json`; пользовательские (инв. 37, строка
//  `app_settings`) переопределяют встроенные по `id` («Поведение»).
//
//  Версия для профиля (инв. 35): профиль называет модель только `id`; кандидаты — все версии
//  этого `id` в действующем каталоге И модели на диске без записи в каталоге (инв. 33).
//  Выбирается новейшая по SemVer 2.0.0 §11 (`ModelVersionOrder`, MEE-458) среди готовых
//  (`downloaded`/`loaded`). Готовой нет — `resolve` бросает `notDownloaded`, `missingModels`
//  называет новейшую версию каталога. Модели с этим `id` нет нигде — `unknownModel(id:version: "")`
//  (инв. 34, пользовательский профиль: его модель законно исчезает после `refreshCatalog`).

import Foundation
import DomainCore

extension ModelCatalogManager {

    /// Без броска (сигнатура порта): строка пользовательских не читается — только встроенные (инв. 37).
    public func profiles() async -> [TranscriptionProfile] {
        effectiveProfiles(user: (try? await loadUserProfiles()) ?? [:])
    }

    public func saveProfile(_ profile: TranscriptionProfile) async throws {
        guard !profile.isBuiltIn else {
            throw ModelCatalogError.builtInProfileImmutable(id: profile.id)
        }
        // Порядок отказов (инв. 13 v7, правка 7908dbf9): builtInProfileImmutable → unknownModel →
        // userProfilesUnreadable → StorageError записи — сначала видное из самого входа, затем
        // требующее чтения хранилища.
        try await withProfileWriteLock {
            // Инв. 13 (v7): все четыре роли, в порядке asr, vad, diarization, embedding.
            for modelId in Self.modelIds(of: profile) where versionCandidates(modelId: modelId).isEmpty {
                throw ModelCatalogError.unknownModel(id: modelId, version: Self.unnamedVersion)
            }
            var current = try await loadUserProfiles()
            current[profile.id] = profile
            try await storeUserProfiles(current)
        }
    }

    public func deleteProfile(id: String) async throws {
        try await withProfileWriteLock {
            var current = try await loadUserProfiles()
            if current.removeValue(forKey: id) != nil {
                try await storeUserProfiles(current)
                return
            }
            if catalog.profiles.contains(where: { $0.id == id }) {
                throw ModelCatalogError.builtInProfileImmutable(id: id)
            }
            throw ModelCatalogError.unknownProfile(id: id)
        }
    }

    public func resolve(profileId: String) async throws -> ResolvedProfile {
        let profile = try await profile(profileId)
        guard let asr = readyBundle(modelId: profile.asrModelId) else {
            let candidates = versionCandidates(modelId: profile.asrModelId)
            guard let newest = newestCatalogDescriptor(modelId: profile.asrModelId) ?? candidates.first else {
                throw ModelCatalogError.unknownModel(id: profile.asrModelId, version: Self.unnamedVersion)
            }
            throw ModelCatalogError.notDownloaded(modelId: profile.asrModelId, version: newest.version)
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
        let profile = try await profile(profileId)
        var missing: [ModelDescriptor] = []
        for modelId in Self.modelIds(of: profile) where readyBundle(modelId: modelId) == nil {
            guard let descriptor = newestCatalogDescriptor(modelId: modelId)
                    ?? versionCandidates(modelId: modelId).first else {
                // Инв. 34: модели нет ни в каталоге, ни на диске (инв. 33); версии профиль не называет.
                throw ModelCatalogError.unknownModel(id: modelId, version: Self.unnamedVersion)
            }
            missing.append(descriptor)
        }
        return missing
    }

    // MARK: - Справки

    /// `version` в `unknownModel`, когда модель названа профилем (только `id`, C-014 §3):
    /// пустая строка — «профиль называет модель без версии» (инв. 13, 34).
    static let unnamedVersion = ""

    func effectiveProfiles(user: [String: TranscriptionProfile]) -> [TranscriptionProfile] {
        let builtIn = catalog.profiles.map { user[$0.id] ?? $0 }
        let builtInIds = Set(catalog.profiles.map(\.id))
        let userOnly = user.values
            .filter { !builtInIds.contains($0.id) }
            .sorted { $0.id < $1.id }
        return builtIn + userOnly
    }

    private func profile(_ id: String) async throws -> TranscriptionProfile {
        let user = try await loadUserProfiles()
        guard let profile = effectiveProfiles(user: user).first(where: { $0.id == id }) else {
            throw ModelCatalogError.unknownProfile(id: id)
        }
        return profile
    }

    private func newestCatalogDescriptor(modelId: String) -> ModelDescriptor? {
        catalog.models
            .filter { $0.id == modelId }
            .max { ModelVersionOrder.isNewer($1.version, than: $0.version) }
    }

    /// Все версии `modelId` (инв. 35): записи действующего каталога и модели на диске без записи
    /// (валидный `.manifest.json`, инв. 33) — от новейшей по SemVer §11 к старейшей.
    func versionCandidates(modelId: String) -> [ModelDescriptor] {
        var candidates = catalog.models.filter { $0.id == modelId }
        let listed = Set(candidates.map(\.version))
        for entry in ModelDisk.modelDirectories(root: layout.root)
        where entry.key.id == modelId && !listed.contains(entry.key.version) {
            if case .model(let descriptor, _)? = locate(entry.key) {
                candidates.append(descriptor)
            }
        }
        return candidates.sorted { ModelVersionOrder.isNewer($0.version, than: $1.version) }
    }

    /// Бандл новейшей готовой версии модели (инв. 35); `nil` — ни одна версия не готова.
    func readyBundle(modelId: String) -> ModelBundle? {
        for descriptor in versionCandidates(modelId: modelId) {
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
