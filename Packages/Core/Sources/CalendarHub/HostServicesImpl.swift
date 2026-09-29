//  HostServicesImpl — реальная реализация ConnectorHostServices (C-006 §4/§6), которую
//  calendar-hub передаёт коннектору при `initialize`. К11 (секреты, Ш1), К14 (лог),
//  К61 (уведомление → внутренняя syncOne, развилка Р6).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен

import Foundation
import DomainCore

/// `log`/`notify` в `ConnectorHostServices` объявлены НЕ `async` (компилятор тем самым
/// гарантирует «не блокирует вызывающего» — К14, возврат РП по MEE-347 снял прежний
/// непроверяемый рантайм-вектор).
///
/// MEE-446: `log` и `notify` с видом, отличным от `.changesAvailable`, пишут СИНХРОННО в
/// `HostEventLog` (под замком, не через актор) — к возврату вызова запись уже видна. Прежний
/// `Task { await hub.… }` доходил до актора позже, и вызов хаба, дождавшийся ответа
/// stdio-коннектора (К47), мог вернуться раньше записи. `.changesAvailable` (К61) по-прежнему
/// уходит в `Task`: `syncOne` — асинхронная работа, ждать её внутри `notify` значило бы
/// заблокировать коннектора (К14), а на stdio-пути ещё и повиснуть на слоте вызова (К12),
/// который держит тот самый разбор ответа, внутри которого пришло уведомление.
final class HostServicesImpl: ConnectorHostServices, @unchecked Sendable {

    private let secretStore: SecretStore
    private let namespace: String
    private weak var hub: CalendarPortImpl?
    private let eventLog: HostEventLog
    private let source: CalendarSourceId

    init(
        secretStore: SecretStore,
        namespace: String,
        hub: CalendarPortImpl,
        eventLog: HostEventLog,
        source: CalendarSourceId
    ) {
        self.secretStore = secretStore
        self.namespace = namespace
        self.hub = hub
        self.eventLog = eventLog
        self.source = source
    }

    func secretGet(key: String) async throws -> String? {
        try await secretStore.get(key: key, namespace: namespace)
    }

    func secretSet(key: String, value: String?) async throws {
        try await secretStore.set(key: key, value: value, namespace: namespace)
    }

    func log(_ level: LogLevel, _ message: String) {
        guard hub != nil else { return }
        eventLog.recordLog(level: level, message: message, source: source)
    }

    func notify(_ kind: HostNotificationKind, detail: String?) {
        guard let hub else { return }
        guard kind == .changesAvailable else {
            eventLog.recordNotification(kind: kind, detail: detail, source: source)
            return
        }
        let source = source
        Task { await hub.handlePushNotification(source: source) }
    }
}
