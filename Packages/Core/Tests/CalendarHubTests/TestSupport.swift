//  Оснастка тестов модуля calendar-hub — план проверки MEE-361, §1.
//
//  * `FakeWaitSeam` — Ш3. По умолчанию `sleep(for:)` возвращается немедленно, записывая
//    запрошенную длительность (тот же приём, что К44 требует для таймера — счёт запросов,
//    не измерение реального времени). `setAutoResolve(false)` переключает в режим ворот —
//    вызов подвешивается до `resolveNext()`/`resolveAll()`, нужен К67 (отмена во время
//    ожидания даёт `.cancelled`).
//  * `FakeSecretStore` — Ш1.
//  * `Harness` — актор `CalendarPortImpl` на подставленном мире, с фейковыми коннекторами
//    по числу источников.

import Foundation
import DomainCore
import DomainTestKit
import CalendarHub

final class FakeWaitSeam: WaitSeam, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedDurations: [Duration] = []
    private var autoResolve = true
    private var pending: [CheckedContinuation<Void, Error>] = []

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var durations: [Duration] { locked { recordedDurations } }

    func setAutoResolve(_ value: Bool) { locked { autoResolve = value } }

    func sleep(for duration: Duration) async throws {
        locked { recordedDurations.append(duration) }
        guard !locked({ autoResolve }) else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                locked { pending.append(continuation) }
            }
        } onCancel: {
            let waiting = locked { () -> [CheckedContinuation<Void, Error>] in
                let list = pending
                pending.removeAll()
                return list
            }
            for continuation in waiting { continuation.resume(throwing: CancellationError()) }
        }
    }

    /// Отпускает САМЫЙ РАННИЙ подвешенный вызов `sleep(for:)`.
    func resolveNext() {
        let continuation = locked { pending.isEmpty ? nil : pending.removeFirst() }
        continuation?.resume()
    }

    func resolveAll() {
        let waiting = locked { () -> [CheckedContinuation<Void, Error>] in
            let list = pending
            pending.removeAll()
            return list
        }
        for continuation in waiting { continuation.resume() }
    }
}

final class FakeSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: [String: String]] = [:]
    private var calls: [(key: String, namespace: String)] = []

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var recordedCalls: [(key: String, namespace: String)] { locked { calls } }

    func get(key: String, namespace: String) async throws -> String? {
        locked {
            calls.append((key, namespace))
            return storage[namespace]?[key]
        }
    }

    func set(key: String, value: String?, namespace: String) async throws {
        locked {
            calls.append((key, namespace))
            if let value {
                storage[namespace, default: [:]][key] = value
            } else {
                storage[namespace]?[key] = nil
            }
        }
    }
}

struct Harness {
    let connectorRepository = InMemoryConnectorRepository()
    let meetingRepository = InMemoryMeetingRepository()
    let waitSeam = FakeWaitSeam()
    let secretStore = FakeSecretStore()
    let connectors: [String: FakeCalendarConnector]
    let hub: CalendarPortImpl

    init(sourceIds: [String]) {
        var connectorMap: [CalendarSourceId: CalendarConnector] = [:]
        var fakes: [String: FakeCalendarConnector] = [:]
        for id in sourceIds {
            let fake = FakeCalendarConnector()
            connectorMap[CalendarSourceId(rawValue: id)] = fake
            fakes[id] = fake
        }
        connectors = fakes
        hub = CalendarPortImpl(
            connectorRepository: connectorRepository, meetingRepository: meetingRepository,
            waitSeam: waitSeam, secretStore: secretStore, connectors: connectorMap
        )
    }

    func connector(_ id: String) -> FakeCalendarConnector {
        guard let connector = connectors[id] else { preconditionFailure("нет фейка на источник \(id)") }
        return connector
    }

    static func record(
        id: String, cursor: String? = nil, selectedCalendarIds: [String] = [], lastSyncAt: Date? = nil
    ) -> ConnectorRecord {
        ConnectorRecord(
            id: id, type: "fake", pluginId: nil, settingsJson: Data("{}".utf8), keychainNamespace: id,
            selectedCalendarIds: selectedCalendarIds, isEnabled: true, lastSyncAt: lastSyncAt,
            cursor: cursor, lastError: nil
        )
    }
}
