//  ModelCatalogManager — удаление и расписки `beginUse`/`endUse` (C-014 v7 §4.1; инв. 6, 11,
//  21–23, 33, 35).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  `loaded` — счётчик невозвращённых расписок (§4.1): больше нуля — `loaded`, ноль —
//  состояние по диску. Счётчик живёт в памяти процесса и не переживает перезапуск (инв. 24).

import Foundation
import DomainCore

extension ModelCatalogManager {

    public func delete(id: String, version: String) async throws {
        // Инв. 37 (уточнение 29.09, MEE-453 a5bc1d63): без строки пользовательских профилей
        // неизвестно, какие версии они держат по инв. 11, — `userProfilesUnreadable`, ничего не
        // удаляется (отказ обратим, удаление — нет). Чтение — до всех проверок: после `await`
        // состояние перечитывается заново.
        let user = try await loadUserProfiles()
        let key = ModelKey(id: id, version: version)
        let directory: URL
        switch locate(key) {
        case .model(_, let found)?, .invalidManifest(_, let found)?:
            directory = found
        case nil:
            throw ModelCatalogError.unknownModel(id: id, version: version)
        }
        // Инв. 11 (v7): мешает профиль, который разрешает сейчас именно эту версию — новейшую
        // готовую (инв. 35) в любой из четырёх ролей; каждая роль защищается независимо, в том
        // числе когда `asr` не готова. Старую и недокачанную версии удалять можно.
        let referencing = effectiveProfiles(user: user)
            .filter { profile in
                Self.modelIds(of: profile).contains { $0 == id && readyBundle(modelId: $0)?.version == version }
            }
            .map(\.id)
            .sorted()
        guard referencing.isEmpty else {
            throw ModelCatalogError.modelInUseByProfile(modelId: id, profileIds: referencing)
        }
        // Инв. 6, 11 (v7): из `loaded` переход только в `downloaded` — модель под непогашенной
        // распиской, которую ни один профиль сейчас не разрешает, даёт `modelInUse`.
        guard useCounts[key, default: 0] == 0 else {
            throw ModelCatalogError.modelInUse(modelId: id, version: version)
        }
        if let session = sessions[key] {
            session.deleted = true
            session.stop()
            sessions[key] = nil
        }
        try ModelDisk.remove(directory)
        failures[key] = nil
        verified[key] = nil
        publish(key, currentState(key))
    }

    public func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken {
        let keys = bundles.map { ModelKey(id: $0.modelId, version: $0.version) }
        // Инв. 22: сначала проверка всего набора, пометка — только если годен целиком.
        for key in keys {
            switch currentState(key) {
            case .downloaded, .loaded:
                continue
            default:
                throw ModelCatalogError.notDownloaded(modelId: key.id, version: key.version)
            }
        }
        let token = ModelUseToken(rawValue: UUID())
        tokens[token.rawValue] = keys
        for key in keys {
            useCounts[key, default: 0] += 1
            publish(key, currentState(key))
        }
        return token
    }

    public func endUse(_ token: ModelUseToken) async {
        // Инв. 23: повторное и чужое погашение — без эффекта.
        guard let keys = tokens.removeValue(forKey: token.rawValue) else { return }
        for key in keys {
            let remaining = useCounts[key, default: 0] - 1
            useCounts[key] = remaining > 0 ? remaining : nil
            publish(key, currentState(key))
        }
    }

    static func modelIds(of profile: TranscriptionProfile) -> [String] {
        [profile.asrModelId, profile.vadModelId, profile.diarizationModelId, profile.embeddingModelId]
            .compactMap { $0 }
    }
}
