//  ModelCatalogManager — удаление и расписки `beginUse`/`endUse` (C-014 v6 §4.1; инв. 6, 11,
//  21–23, 33).
//
//  Модуль: model-manager · Владелец: DEV-2 · Слой: домен + адаптер сети
//
//  `loaded` — счётчик невозвращённых расписок (§4.1): больше нуля — `loaded`, ноль —
//  состояние по диску. Счётчик живёт в памяти процесса и не переживает перезапуск (инв. 24).

import Foundation
import DomainCore

extension ModelCatalogManager {

    public func delete(id: String, version: String) async throws {
        let key = ModelKey(id: id, version: version)
        let directory: URL
        switch locate(key) {
        case .model(_, let found)?, .invalidManifest(_, let found)?:
            directory = found
        case nil:
            throw ModelCatalogError.unknownModel(id: id, version: version)
        }
        let referencing = effectiveProfiles()
            .filter { profile in Self.modelIds(of: profile).contains(id) }
            .map(\.id)
        guard referencing.isEmpty else {
            throw ModelCatalogError.modelInUseByProfile(modelId: id, profileIds: referencing)
        }
        // Инв. 6: из `loaded` переход только в `downloaded`. Модель под непогашенной распиской
        // не удаляется; код ошибки контракт не называет — отказ тем же случаем, без профилей.
        guard useCounts[key, default: 0] == 0 else {
            throw ModelCatalogError.modelInUseByProfile(modelId: id, profileIds: [])
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
