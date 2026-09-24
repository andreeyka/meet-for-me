//  Заглушка `ModelCatalogPort` — C-013 v8, «Чем проверяется»: «объявленная в самих
//  DomainCoreTests» дословно, не в `DomainTestKit`. `DomainTestKit.FakeModelCatalogPort`
//  (C-014) для этого не расширяется намеренно — тот же довод, что называет контракт: «тому
//  ей нужен управляемый отказ именно этого метода — тест очереди, — а заводить ради него
//  правку принятого контракта не за что».
//
//  Считает только ОБЩЕЕ число вызовов `missingModels`: «не чаще одного вызова на различный
//  profileId за пересмотр» (инвариант 20) — свойство КЭША в самой очереди, а не заглушки;
//  заглушка честно отражает, сколько раз её действительно спросили.

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
}
