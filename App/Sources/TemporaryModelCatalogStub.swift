//  TemporaryModelCatalogStub — временная заглушка `ModelCatalogPort` до готовности
//  model-manager (MEE-429). MEE-433, решение РП п.5: `FakeModelCatalogPort` лежит в
//  `DomainTestKit` (тестовый таргет) — тянуть его в релизный App нельзя, поэтому composition
//  root заводит собственный тип продуктового таргета `MeetForMe`.
//
//  УДАЛИТЬ ВМЕСТЕ С MEE-429 — на её место встаёт настоящий model-manager.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: composition root (временная заглушка)

import DomainCore
import Foundation

struct TemporaryModelCatalogStub: ModelCatalogPort {

    private static let unavailable = ModelCatalogError.manifestUnreachable(
        message: "model-manager (MEE-429) ещё не реализован — временная заглушка composition root"
    )

    func refreshCatalog() async throws { throw Self.unavailable }
    func models() async -> [ModelDescriptor] { [] }
    func model(id: String, version: String) async -> ModelDescriptor? { nil }
    func state(id: String, version: String) async -> ModelState { .error(Self.unavailable) }
    func download(id: String, version: String) async throws { throw Self.unavailable }
    func cancelDownload(id: String, version: String) async {}
    func verify(id: String, version: String) async throws { throw Self.unavailable }
    func delete(id: String, version: String) async throws { throw Self.unavailable }
    func diskUsage() async -> [ModelDiskUsage] { [] }
    func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken { throw Self.unavailable }
    func endUse(_ token: ModelUseToken) async {}
    func profiles() async -> [TranscriptionProfile] { [] }
    func saveProfile(_ profile: TranscriptionProfile) async throws { throw Self.unavailable }
    func deleteProfile(id: String) async throws { throw Self.unavailable }
    func resolve(profileId: String) async throws -> ResolvedProfile { throw Self.unavailable }
    func missingModels(profileId: String) async throws -> [ModelDescriptor] { throw Self.unavailable }
    func events() -> AsyncStream<ModelCatalogEvent> { AsyncStream { $0.finish() } }
}
