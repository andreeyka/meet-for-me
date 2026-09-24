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

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
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
        if let error = locked({ failures[profileId] }) {
            throw error
        }
        return locked { missing[profileId] } ?? []
    }
}
