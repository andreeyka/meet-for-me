//  FakeModelCatalogPort — настройка тестом и честный счётчик расписок, разнесённые по
//  объёму (`type_body_length` SwiftLint), не по смыслу — `extension` того же класса, что
//  и `FakeModelCatalogPort.swift`. Хранилище живёт там.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)

import Foundation
import DomainCore

extension FakeModelCatalogPort {

    // MARK: - Настройка тестом

    /// Дописывает каталог — не заменяет: уже зарегистрированные дескрипторы, которых нет в
    /// новом наборе, остаются; дескриптор с тем же `(id, version)` перезаписывается. Тест
    /// волен звать `setCatalog` до `setState` в любом порядке и накапливать вызовами.
    public func setCatalog(_ descriptors: [ModelDescriptor]) {
        locked {
            for descriptor in descriptors {
                descriptorsByKey[ModelKey(id: descriptor.id, version: descriptor.version)] = descriptor
            }
        }
    }

    /// Базовое состояние модели. `.loaded` сюда можно передать, но `state(id:version:)`
    /// отдаст его лишь пока нет ни одной непогашенной расписки (см. заголовок, п. 1) —
    /// иначе используй настоящий `beginUse`.
    public func setState(_ state: ModelState, forId id: String, version: String) {
        locked { statesByKey[ModelKey(id: id, version: version)] = state }
    }

    public func setProfiles(_ profiles: [TranscriptionProfile]) {
        locked {
            for profile in profiles { profilesById[profile.id] = profile }
        }
    }

    /// `nil` снимает отказ. Персистентно, пока не снят или не заменён — тем же приёмом,
    /// что `failSync(with:for:)`/`setFailure(_:for:)` у соседних фейков.
    public func failDownload(_ error: ModelCatalogError?, forId id: String, version: String) {
        locked { downloadFailures[ModelKey(id: id, version: version)] = error }
    }

    public func failDelete(_ error: ModelCatalogError?, forId id: String, version: String) {
        locked { deleteFailures[ModelKey(id: id, version: version)] = error }
    }

    public func failResolve(_ error: ModelCatalogError?, forProfileId profileId: String) {
        locked { resolveFailures[profileId] = error }
    }

    /// Проталкивает `ModelCatalogEvent` в поток(и) `events()`, ровно как есть.
    public func pushEvent(_ event: ModelCatalogEvent) {
        let targets = locked { eventContinuations }
        for continuation in targets { continuation.yield(event) }
    }

    /// Закрыть поток(и) `events()`: подписчики досматривают выданное и выходят из цикла.
    public func finishEvents() {
        let targets = locked { () -> [AsyncStream<ModelCatalogEvent>.Continuation] in
            let taken = eventContinuations
            eventContinuations = []
            return taken
        }
        for continuation in targets { continuation.finish() }
    }

    // MARK: - Расписки — честный счётчик (§«Фейк для тестов»)

    /// Сколько раз `beginUse` УСПЕШНО выдал расписку.
    public var beginUseSuccessCount: Int { locked { beginUseSuccesses } }

    /// Сколько раз `endUse` ВООБЩЕ позвали — включая холостые вызовы на неизвестную или
    /// уже погашенную расписку (инвариант 23: они не эффект, но они звонок).
    public var endUseCallCount: Int { locked { endUseCalls } }

    /// Сколько из вызовов `endUse` РЕАЛЬНО погасили непогашенную расписку.
    public var endUseEffectiveCount: Int { locked { endUseEffective } }

    /// Сколько расписок сейчас не погашено.
    public var outstandingUseTokenCount: Int { locked { outstandingTokens.count } }
}
