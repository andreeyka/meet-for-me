//  Швы модуля calendar-hub — C-006 §4/§5.2 (перечень MEE-347, раздел «Шов»).
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен
//
//  Место объявления обоих протоколов транспорта/секретов — сам calendar-hub (не
//  DomainCore/DomainTestKit): C-006 v9 (IR-118) закрыла запрещённое ребро графа
//  DomainTestKit → CalendarHub именно так — тестовые реализации живут в CalendarHubTests,
//  которому свой модуль виден по построению. Перечень MEE-347 называет операции каждого
//  шва дословно; форму (имя протокола, состав методов) выбирает эта задача — не цитата.

import Foundation

/// Хранилище секретов коннекторов (C-006 §4, инв. 11-12; Ш1). `namespace` —
/// `connectorInstanceId` (C-010 v13: `keychain_namespace` — тождество с ним, не отдельное
/// значение — перечень MEE-347, К11). Реальная реализация на Keychain — не в calendar-hub
/// (находка 1 перечня, открыта: владелец ещё не назначен архитектором, IR-122/MEE-358).
public protocol SecretStore: Sendable {
    func get(key: String, namespace: String) async throws -> String?
    /// `value == nil` удаляет запись, не пишет пустую строку.
    func set(key: String, value: String?, namespace: String) async throws
}

/// Транспорт stdio (C-006 §2; Ш2). Контракт называет только тестовую реализацию
/// (`ScriptedRPCTransport`), не сам шов, которым хост её принимает (C-006 v9, инв. 21(г),
/// дословно у перечня MEE-347: «о типе, которым хост принимает транспорт: контракт не
/// называет его ни одной строкой»). Форма — решение этой задачи.
public protocol RPCTransport: Sendable {
    func send(_ frame: String) async throws
    func receive() async throws -> String
}

/// Шов ожидания (C-006 §5.2) — контрактом специфицирован полностью как
/// `sleep(for: Duration) async throws`, но обслуживает одной инъекцией три разных
/// обязательства: таймаут-политику «Поведения» (10/120/30с), политику повторов §5.2 и
/// таймер опроса (развилка Р5). Реализация по умолчанию (реальный `Task.sleep`) — вне
/// calendar-hub, у composition root (перечень MEE-347, раздел «Шов»).
public protocol WaitSeam: Sendable {
    func sleep(for duration: Duration) async throws
}
