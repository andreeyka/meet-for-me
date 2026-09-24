//  HostServicesImpl — реальная реализация ConnectorHostServices (C-006 §4/§6), которую
//  calendar-hub передаёт коннектору при `initialize`. К11 (секреты, Ш1), К14 (лог),
//  К61 (уведомление → внутренняя syncOne, развилка Р6).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import DomainCore

/// `log`/`notify` в `ConnectorHostServices` объявлены НЕ `async` (компилятор тем самым
/// гарантирует «не блокирует вызывающего» — К14, возврат РП по MEE-347 снял прежний
/// непроверяемый рантайм-вектор). Чтобы записать вызов в состояние актора, не блокируя
/// коннектора, каждый из них заводит `Task`, а не зовёт актор напрямую.
final class HostServicesImpl: ConnectorHostServices, @unchecked Sendable {

    private let secretStore: SecretStore
    private let namespace: String
    private weak var hub: CalendarPortImpl?
    private let source: CalendarSourceId

    init(secretStore: SecretStore, namespace: String, hub: CalendarPortImpl, source: CalendarSourceId) {
        self.secretStore = secretStore
        self.namespace = namespace
        self.hub = hub
        self.source = source
    }

    func secretGet(key: String) async throws -> String? {
        try await secretStore.get(key: key, namespace: namespace)
    }

    func secretSet(key: String, value: String?) async throws {
        try await secretStore.set(key: key, value: value, namespace: namespace)
    }

    func log(_ level: LogLevel, _ message: String) {
        guard let hub else { return }
        Task { await hub.recordLog(level: level, message: message, source: source) }
    }

    func notify(_ kind: HostNotificationKind, detail: String?) {
        guard let hub else { return }
        Task { await hub.handleNotify(kind: kind, detail: detail, source: source) }
    }
}
