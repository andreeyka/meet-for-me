//  PreSendCancellationFakes — фейки портов для MEE-510 (C-012 v13 §3.2, инв. 12; IR-154 п. 2):
//  хранилище записей и каталог моделей, бросающие заданную ошибку до отправки запроса, и
//  каталог, встающий в `resolve` до отмены `Task` (сквозной тест «очередь отменила во время
//  `resolve`»).
//
//  Модуль: engine-xpc (тесты) · Владелец: DEV-2

import Foundation
import DomainCore
import DomainTestKit

/// `RecordingRepository`, у которого `recording(id:)` бросает заданную ошибку и считает вызовы.
/// `StorageError`-отказы `InMemoryRecordingRepository.fail(with:on:)` сюда не подходят:
/// `CancellationError` — не `StorageError`.
final class ThrowingRecordingRepository: RecordingRepository, @unchecked Sendable {
    private let lock = NSLock()
    private let error: Error
    private var recordingCallsValue = 0

    init(error: Error) { self.error = error }

    var recordingCalls: Int {
        lock.lock(); defer { lock.unlock() }
        return recordingCallsValue
    }

    func recording(id: UUID) async throws -> RecordingRecord? {
        lock.lock(); recordingCallsValue += 1; lock.unlock()
        throw error
    }

    func save(_ record: RecordingRecord) async throws {}
    func recordings(meetingId: UUID) async throws -> [RecordingRecord] { [] }
    func unfinalized() async throws -> [RecordingRecord] { [] }
    func adHoc() async throws -> [RecordingRecord] { [] }
    func delete(recordingId: UUID, deleteFiles: Bool) async throws {}
    func createDirectory(recordingId: UUID) async throws -> URL {
        URL(fileURLWithPath: "/dev/null").appendingPathComponent(recordingId.uuidString)
    }
}

/// Задвижка «пришли в `resolve`»: тест ждёт прихода и только тогда отменяет `Task`.
final class ArrivalFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = false

    var hasArrived: Bool {
        lock.lock(); defer { lock.unlock() }
        return arrived
    }

    func mark() {
        lock.lock(); arrived = true; lock.unlock()
    }
}

/// `ModelCatalogPort` поверх `FakeModelCatalogPort`: `resolve`/`beginUse` бросают заданную
/// ошибку до обращения к базе. `suspendResolveUntilCancelled` — `resolve` встаёт в
/// `Task.sleep` и бросает его `CancellationError`, когда вызывающий `Task` отменён: так
/// наблюдаемо ведёт себя реальный порт, отменённый во время ожидания.
final class ThrowingModelCatalog: ModelCatalogPort, @unchecked Sendable {
    private let base: FakeModelCatalogPort
    private let resolveError: Error?
    private let beginUseError: Error?
    private let resolveArrival: ArrivalFlag?

    init(
        base: FakeModelCatalogPort, resolveError: Error? = nil, beginUseError: Error? = nil,
        suspendResolveUntilCancelled resolveArrival: ArrivalFlag? = nil
    ) {
        self.base = base
        self.resolveError = resolveError
        self.beginUseError = beginUseError
        self.resolveArrival = resolveArrival
    }

    func resolve(profileId: String) async throws -> ResolvedProfile {
        if let resolveArrival {
            resolveArrival.mark()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        if let resolveError { throw resolveError }
        return try await base.resolve(profileId: profileId)
    }

    func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken {
        if let beginUseError { throw beginUseError }
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
