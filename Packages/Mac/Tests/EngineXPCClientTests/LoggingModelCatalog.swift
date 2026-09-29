//  LoggingModelCatalog — `ModelCatalogPort` с общим с `InMemoryRecordingRepository` журналом
//  вызовов (инв. 24). Записи и манифесты C-012 v12 §1.1 — `RecordingFixtures` из
//  `DomainTestKit` (MEE-495, п. 2).
//
//  Модуль: engine-xpc (тесты) · Владелец: DEV-2

import Foundation
import DomainCore
import DomainTestKit

/// `ModelCatalogPort`, пишущий `resolve`/`beginUse` в общий с `InMemoryRecordingRepository`
/// журнал — порядок «запись раньше модели» (инв. 24) читается одним журналом.
final class LoggingModelCatalog: ModelCatalogPort, Sendable {
    static let portName = "ModelCatalogPort"
    private let base: FakeModelCatalogPort
    private let log: PortCallLog

    init(base: FakeModelCatalogPort, log: PortCallLog) {
        self.base = base
        self.log = log
    }

    func resolve(profileId: String) async throws -> ResolvedProfile {
        log.record(port: Self.portName, method: "resolve(profileId:)", arguments: [profileId])
        return try await base.resolve(profileId: profileId)
    }

    func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken {
        log.record(port: Self.portName, method: "beginUse(_:)")
        return try await base.beginUse(bundles)
    }

    func endUse(_ token: ModelUseToken) async { await base.endUse(token) }
    func refreshCatalog() async throws { try await base.refreshCatalog() }
    func models() async -> [ModelDescriptor] { await base.models() }
    func model(id: String, version: String) async -> ModelDescriptor? { await base.model(id: id, version: version) }
    func state(id: String, version: String) async -> ModelState { await base.state(id: id, version: version) }
    func download(id: String, version: String) async throws { try await base.download(id: id, version: version) }
    func cancelDownload(id: String, version: String) async { await base.cancelDownload(id: id, version: version) }
    func verify(id: String, version: String) async throws { try await base.verify(id: id, version: version) }
    func delete(id: String, version: String) async throws { try await base.delete(id: id, version: version) }
    func diskUsage() async -> [ModelDiskUsage] { await base.diskUsage() }
    func profiles() async -> [TranscriptionProfile] { await base.profiles() }
    func saveProfile(_ profile: TranscriptionProfile) async throws { try await base.saveProfile(profile) }
    func deleteProfile(id: String) async throws { try await base.deleteProfile(id: id) }
    func missingModels(profileId: String) async throws -> [ModelDescriptor] {
        try await base.missingModels(profileId: profileId)
    }
    func events() -> AsyncStream<ModelCatalogEvent> { base.events() }
}
