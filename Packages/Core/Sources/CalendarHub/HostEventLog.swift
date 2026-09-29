//  HostEventLog — журнал вызовов `log`/`notify` коннектора (К14, К61), общий для
//  `CalendarPortImpl` и `HostServicesImpl`.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен
//
//  ПОЧЕМУ ОТДЕЛЬНО ОТ АКТОРА И ПОД ЗАМКОМ (MEE-446): `log`/`notify` в `ConnectorHostServices`
//  объявлены НЕ `async` (К14 — не блокирует вызывающего), значит синхронно в состояние
//  актора из них не попасть. Прежняя реализация заводила `Task { await hub.record…(…) }` —
//  и запись доходила до актора КОГДА-НИБУДЬ ПОСЛЕ возврата `log`/`notify`. stdio-коннектор
//  разбирает `host/log`/`host/notify` внутри ожидания ответа (К47): вызов хаба, дождавшийся
//  ответа, мог вернуться раньше, чем эти `Task` исполнились, — отсюда нестабильный
//  `test_k47_…` на macOS (`recordedNotifications` пуст сразу после `listCalendars`).
//  Здесь запись делается синхронно, под `NSLock`, в самом вызове `log`/`notify` — к моменту
//  их возврата она уже видна читателю. Замок держится только на время дописывания/чтения
//  массива — вызывающий не блокируется ничем, кроме этого.

import Foundation
import DomainCore

final class HostEventLog: @unchecked Sendable {

    private let lock = NSLock()
    private var logEntries: [CalendarSourceId: [(level: LogLevel, message: String)]] = [:]
    private var notifyEntries: [CalendarSourceId: [(kind: HostNotificationKind, detail: String?)]] = [:]

    /// Своя обёртка, а не `NSLocking.withLock`: та пришла в Foundation позже минимальной
    /// версии тулчейна CI `Core (Linux)` (тот же довод, что у `SessionChangeHub`).
    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func recordLog(level: LogLevel, message: String, source: CalendarSourceId) {
        locked { logEntries[source, default: []].append((level, message)) }
    }

    func recordNotification(kind: HostNotificationKind, detail: String?, source: CalendarSourceId) {
        locked { notifyEntries[source, default: []].append((kind, detail)) }
    }

    func loggedEntries(for source: CalendarSourceId) -> [(level: LogLevel, message: String)] {
        locked { logEntries[source] ?? [] }
    }

    func recordedNotifications(for source: CalendarSourceId) -> [(kind: HostNotificationKind, detail: String?)] {
        locked { notifyEntries[source] ?? [] }
    }
}
