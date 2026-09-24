//  Заглушка `ModelCatalogPort` — C-013 v8, «Чем проверяется»: «объявленная в самих
//  DomainCoreTests» дословно, не в `DomainTestKit`. `DomainTestKit.FakeModelCatalogPort`
//  (C-014) для этого не расширяется намеренно — тот же довод, что называет контракт: «тому
//  ей нужен управляемый отказ именно этого метода — тест очереди, — а заводить ради него
//  правку принятого контракта не за что».
//
//  Считает только ОБЩЕЕ число вызовов `missingModels`: «не чаще одного вызова на различный
//  profileId за пересмотр» (инвариант 20) — свойство КЭША в самой очереди, а не заглушки;
//  заглушка честно отражает, сколько раз её действительно спросили.
//
//  С MEE-395 (исход (б) развилки, полный порт C-014 v6) `ModelCatalogPort` несёт ещё
//  шестнадцать требований — эта заглушка их не проверяет и не эмулирует: очередь зовёт
//  только `missingModels` (C-013 §1.1). Остальные — `preconditionFailure`: тест этого
//  файла, дозвавшийся до одного из них, ошибся портом, а не проверяет то, что думает.

import Foundation
import DomainCore

enum StubModelCatalogError: Error {
    case unknownProfile(id: String)
    case other(String)
}

final class StubModelCatalogPort: ModelCatalogPort, @unchecked Sendable {

    private let lock = NSLock()
    private var missing: [String: [ModelDescriptor]] = [:]
    private var failures: [String: Error] = [:]
    private var calls = 0
    private var gatedProfileId: String?
    private var gateContinuation: CheckedContinuation<Void, Never>?

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// К70 (усиление по возврату РП, MEE-350): держит следующий вызов `missingModels` для
    /// заданного `profileId` подвешенным до `releaseGatedCall()` — способ дать тесту РЕАЛЬНУЮ,
    /// а не подставную, точку останова внутри `firstBlockingReason` (между тем, как `claimNext`
    /// уже пометил строку `running`, и тем, как пересмотр решил её судьбу), не трогая
    /// `DomainTestKit`. Актор `JobQueueEngine` при этом свободен обработать параллельный
    /// `stop()` — приостановленный `await` отдаёт исполнение.
    func pauseNextCall(for profileId: String) {
        locked { gatedProfileId = profileId }
    }

    /// Отпускает вызов, подвешенный `pauseNextCall(for:)`. Без эффекта, если подвешенного нет.
    func releaseGatedCall() {
        let continuation = locked { () -> CheckedContinuation<Void, Never>? in
            defer { gateContinuation = nil }
            return gateContinuation
        }
        continuation?.resume()
    }

    /// Задать ответ «непустой массив» (условие не выполнено) либо «пустой» (выполнено) для
    /// заданного `profileId`.
    func setMissingModels(_ models: [ModelDescriptor], for profileId: String) {
        locked { missing[profileId] = models; failures[profileId] = nil }
    }

    /// Задать отказ, который `missingModels` бросит для заданного `profileId`.
    func setFailure(_ error: Error, for profileId: String) {
        locked { failures[profileId] = error; missing[profileId] = nil }
    }

    var callCount: Int { locked { calls } }

    func missingModels(profileId: String) async throws -> [ModelDescriptor] {
        locked { calls += 1 }
        let shouldGate = locked { () -> Bool in
            guard gatedProfileId == profileId else { return false }
            gatedProfileId = nil
            return true
        }
        if shouldGate {
            await withCheckedContinuation { continuation in
                locked { gateContinuation = continuation }
            }
        }
        if let error = locked({ failures[profileId] }) {
            throw error
        }
        return locked { missing[profileId] } ?? []
    }

    private static func unused(_ method: String) -> Never {
        preconditionFailure("StubModelCatalogPort.\(method) не эмулирует C-014 — им пользуется только missingModels")
    }

    func refreshCatalog() async throws { Self.unused("refreshCatalog") }
    func models() async -> [ModelDescriptor] { Self.unused("models") }
    func model(id: String, version: String) async -> ModelDescriptor? { Self.unused("model(id:version:)") }
    func state(id: String, version: String) async -> ModelState { Self.unused("state(id:version:)") }
    func download(id: String, version: String) async throws { Self.unused("download") }
    func cancelDownload(id: String, version: String) async { Self.unused("cancelDownload") }
    func verify(id: String, version: String) async throws { Self.unused("verify") }
    func delete(id: String, version: String) async throws { Self.unused("delete") }
    func diskUsage() async -> [ModelDiskUsage] { Self.unused("diskUsage") }
    func beginUse(_ bundles: [ModelBundle]) async throws -> ModelUseToken { Self.unused("beginUse") }
    func endUse(_ token: ModelUseToken) async { Self.unused("endUse") }
    func profiles() async -> [TranscriptionProfile] { Self.unused("profiles") }
    func saveProfile(_ profile: TranscriptionProfile) async throws { Self.unused("saveProfile") }
    func deleteProfile(id: String) async throws { Self.unused("deleteProfile") }
    func resolve(profileId: String) async throws -> ResolvedProfile { Self.unused("resolve") }
    func events() -> AsyncStream<ModelCatalogEvent> { Self.unused("events") }
}
