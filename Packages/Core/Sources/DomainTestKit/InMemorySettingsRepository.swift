//  InMemorySettingsRepository — реализация `SettingsRepository` поверх словаря, C-010
//  §«Фейк для тестов». Имя взято у контракта.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ЧТО ДЕРЖИТСЯ ИЗ ИНВАРИАНТОВ (МЕЕ-189, К48, действующая редакция):
//    * инвариант 20 — `value(forKey:)` на отсутствующем ключе отдаёт `nil`, а не отказ.
//      `notFound` этот порт не бросает НИ ОДНИМ методом: ни `value(forKey:)` (чтение), ни
//      `setValue(_:forKey:)` в закрытый список инварианта 20 не входят — `setValue` пишет
//      значение по ключу безусловно (создаёт или заменяет), `nil` снимает ключ.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА.

import Foundation
import DomainCore

/// Метод репозитория настроек — адрес заданного тестом отказа (К47).
public enum SettingsRepositoryMethod: String, Sendable, CaseIterable {
    case value
    case setValue
}

/// Фейк репозитория настроек. Всё поведение задаёт тест.
public final class InMemorySettingsRepository: SettingsRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "SettingsRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var values: [String: Data] = [:]
    private var order: [String] = []
    private var failures: [SettingsRepositoryMethod: (id: String?, error: StorageError)] = [:]

    public init(log: PortCallLog = PortCallLog()) {
        self.log = log
    }

    /// Журнал, в который пишет этот фейк. Тот же объект, что передали в инициализатор.
    public var callLog: PortCallLog { log }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Положить значение мимо `setValue`: вход теста, а не вызов порта. В журнал не пишется.
    public func seed(_ pairs: [String: Data]) {
        locked {
            for (key, value) in pairs {
                if values[key] == nil {
                    order.append(key)
                }
                values[key] = value
            }
        }
    }

    public func fail(with error: StorageError, on method: SettingsRepositoryMethod, id: String? = nil) {
        locked { failures[method] = (id: id, error: error) }
    }

    public func clearFailure(on method: SettingsRepositoryMethod) {
        locked { failures[method] = nil }
    }

    /// Все ключи, для которых сейчас хранится значение, в порядке первого появления.
    public var storedKeys: [String] {
        locked { order.filter { values[$0] != nil } }
    }

    // MARK: - Оснастка

    private func failureIfAny(_ method: SettingsRepositoryMethod, id: String?) -> StorageError? {
        locked { () -> StorageError? in
            guard let failure = failures[method] else { return nil }
            guard let wanted = failure.id else { return failure.error }
            return wanted == id ? failure.error : nil
        }
    }

    // MARK: - SettingsRepository

    public func value(forKey key: String) async throws -> Data? {
        log.record(port: Self.portName, method: "value(forKey:)", arguments: [key])
        if let error = failureIfAny(.value, id: key) {
            throw error
        }
        return locked { values[key] }
    }

    public func setValue(_ value: Data?, forKey key: String) async throws {
        log.record(port: Self.portName, method: "setValue(_:forKey:)", arguments: [key])
        if let error = failureIfAny(.setValue, id: key) {
            throw error
        }
        locked {
            if values[key] == nil, value != nil {
                order.append(key)
            }
            values[key] = value
        }
    }
}
