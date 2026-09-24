//  FakeConnectorHostServices — реализация `ConnectorHostServices` в памяти, C-006 §6.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  СТРОКА: форму этого фейка контракт не называет. Раздел «Фейк для тестов» C-006 задаёт
//  форму `FakeCalendarConnector` (реализация `CalendarConnector`) и `ScriptedRPCTransport`
//  (сценарий stdio-кадров) — оба адресованы будущим `calendar-hub` и `calendar-eventkit` и
//  не входят в предмет этой задачи (MEE-346, «Предмет»). Постановка MEE-346 требует фейка
//  `ConnectorHostServices` отдельно и называет только его обязанность — считать вызовы
//  `secretGet`, `secretSet`, `log` и `notify`, — а не публичную поверхность счётчиков.
//  Взято по конвенции §3 правил проекта и форме уже принятых фейков C-005/C-008/C-009
//  (`PortCallLog`, метод `callCount` через журнал, а не отдельные счётчики): счёт по имени
//  метода читается из общего `PortCallLog`, а хранимые списки `secretStore`/`loggedEntries`/
//  `sentNotifications` держат СОДЕРЖИМОЕ вызовов — считать одно количество без содержимого
//  тесту `calendar-hub` было бы недостаточно ни разу. Владелец — архитектор C-006, условие
//  снятия — контракт называет форму фейка `ConnectorHostServices` поимённо. Срок — не позже
//  первого потребителя (`calendar-hub`, ещё не заведён).
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА: `secretGet`/`secretSet` хранят значения в словаре и не
//  ходят ни в какой Keychain, `log`/`notify` копят записи и никуда их не показывают.

import Foundation
import DomainCore

/// Фейк сервисов хоста для коннектора. Всё поведение задаёт тест.
public final class FakeConnectorHostServices: ConnectorHostServices, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя протокола из контракта, а не имя фейка.
    public static let portName = "ConnectorHostServices"

    private let lock = NSLock()
    private let portLog: PortCallLog

    private var secretStore: [String: String] = [:]
    private var loggedEntries: [(level: LogLevel, message: String)] = []
    private var sentNotifications: [(kind: HostNotificationKind, detail: String?)] = []

    /// - Parameter log: общий журнал вызовов (условие `Н`). Не дали — фейк заводит свой.
    public init(log: PortCallLog = PortCallLog()) {
        self.portLog = log
    }

    /// Журнал, в который пишет этот фейк. Тот же объект, что передали в инициализатор.
    public var callLog: PortCallLog { portLog }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Задать значение секрета заранее — то, что вернёт следующий `secretGet(key:)`.
    /// `nil` — секрета нет, тот же ответ, что и у ключа, которого не задавали ни разу.
    public func setSecret(_ value: String?, for key: String) {
        locked { secretStore[key] = value }
    }

    /// Текущее значение секрета — то, что записал последний `secretSet(key:value:)`,
    /// либо то, что задал тест через `setSecret(_:for:)`, если `secretSet` не звался.
    public func secret(for key: String) -> String? {
        locked { secretStore[key] }
    }

    /// Число вызовов метода протокола по его имени в журнале — `"secretGet(key:)"`,
    /// `"secretSet(key:value:)"`, `"log(_:_:)"`, `"notify(_:detail:)"`.
    public func callCount(_ method: String) -> Int {
        portLog.count(port: Self.portName, method: method)
    }

    /// Записи, переданные в `log(_:_:)`, по порядку вызовов.
    public var loggedMessages: [(level: LogLevel, message: String)] {
        locked { loggedEntries }
    }

    /// Записи, переданные в `notify(_:detail:)`, по порядку вызовов.
    public var notifications: [(kind: HostNotificationKind, detail: String?)] {
        locked { sentNotifications }
    }

    // MARK: - ConnectorHostServices

    public func secretGet(key: String) async throws -> String? {
        portLog.record(port: Self.portName, method: "secretGet(key:)", arguments: [key])
        return locked { secretStore[key] }
    }

    public func secretSet(key: String, value: String?) async throws {
        portLog.record(
            port: Self.portName, method: "secretSet(key:value:)", arguments: [key, value ?? "nil"]
        )
        locked { secretStore[key] = value }
    }

    public func log(_ level: LogLevel, _ message: String) {
        portLog.record(port: Self.portName, method: "log(_:_:)", arguments: [level.rawValue, message])
        locked { loggedEntries.append((level, message)) }
    }

    public func notify(_ kind: HostNotificationKind, detail: String?) {
        portLog.record(
            port: Self.portName, method: "notify(_:detail:)", arguments: [kind.rawValue, detail ?? "nil"]
        )
        locked { sentNotifications.append((kind, detail)) }
    }
}
