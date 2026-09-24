//  InMemoryConnectorRepository — реализация `ConnectorRepository` поверх словаря, C-010
//  §«Фейк для тестов». Имя взято у контракта.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ЧТО ДЕРЖИТСЯ ИЗ ИНВАРИАНТОВ (МЕЕ-189, К48, действующая редакция):
//    * инвариант 20 — чтения отдают пустой массив. `notFound` бросают РОВНО ДВА метода —
//      `setCursor` и `setSyncOutcome` — они и только они входят в закрытый список
//      инварианта 20 («…бросается только методами… `setCursor`, `setSyncOutcome`…»);
//      `upsert` и `delete` в список не входят: `delete` на отсутствующем `connectorId` —
//      операция без эффекта, не отказ.
//
//  `connectorId` — `String`, а не `UUID` (тип поля контракта): ключ хранилища и аргумент
//  отказа те же, без преобразования.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА.

import Foundation
import DomainCore

/// Метод репозитория коннекторов — адрес заданного тестом отказа (К47).
public enum ConnectorRepositoryMethod: String, Sendable, CaseIterable {
    case all
    case upsert
    case setCursor
    case setSyncOutcome
    case delete
}

/// Фейк репозитория коннекторов. Всё поведение задаёт тест.
public final class InMemoryConnectorRepository: ConnectorRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "ConnectorRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var records: [String: ConnectorRecord] = [:]
    private var order: [String] = []
    private var failures: [ConnectorRepositoryMethod: (id: String?, error: StorageError)] = [:]

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

    /// Положить коннекторы мимо `upsert`: вход теста, а не вызов порта. В журнал не пишется.
    public func seed(_ list: [ConnectorRecord]) {
        locked {
            for record in list {
                if records[record.id] == nil {
                    order.append(record.id)
                }
                records[record.id] = record
            }
        }
    }

    public func fail(with error: StorageError, on method: ConnectorRepositoryMethod, id: String? = nil) {
        locked { failures[method] = (id: id, error: error) }
    }

    public func clearFailure(on method: ConnectorRepositoryMethod) {
        locked { failures[method] = nil }
    }

    /// Всё, что лежит в хранилище, в порядке первого появления.
    public var storedRecords: [ConnectorRecord] {
        locked { order.compactMap { records[$0] } }
    }

    // MARK: - Оснастка

    private func failureIfAny(_ method: ConnectorRepositoryMethod, id: String?) -> StorageError? {
        locked { () -> StorageError? in
            guard let failure = failures[method] else { return nil }
            guard let wanted = failure.id else { return failure.error }
            return wanted == id ? failure.error : nil
        }
    }

    // MARK: - ConnectorRepository

    public func all() async throws -> [ConnectorRecord] {
        log.record(port: Self.portName, method: "all()")
        if let error = failureIfAny(.all, id: nil) {
            throw error
        }
        return locked { order.compactMap { records[$0] } }
    }

    public func upsert(_ record: ConnectorRecord) async throws {
        log.record(port: Self.portName, method: "upsert(_:)", arguments: [record.id])
        if let error = failureIfAny(.upsert, id: record.id) {
            throw error
        }
        locked {
            if records[record.id] == nil {
                order.append(record.id)
            }
            records[record.id] = record
        }
    }

    public func setCursor(_ cursor: String?, connectorId: String) async throws {
        log.record(port: Self.portName, method: "setCursor(_:connectorId:)", arguments: [cursor ?? "nil", connectorId])
        if let error = failureIfAny(.setCursor, id: connectorId) {
            throw error
        }
        let existing = locked { records[connectorId] }
        guard let existing else {
            throw StorageError.notFound(entity: "Connector", id: connectorId)
        }
        locked { records[connectorId] = Self.withCursor(existing, cursor: cursor) }
    }

    public func setSyncOutcome(at: Date, error syncError: String?, connectorId: String) async throws {
        log.record(
            port: Self.portName, method: "setSyncOutcome(at:error:connectorId:)",
            arguments: [String(at.timeIntervalSince1970), syncError ?? "nil", connectorId]
        )
        if let error = failureIfAny(.setSyncOutcome, id: connectorId) {
            throw error
        }
        let existing = locked { records[connectorId] }
        guard let existing else {
            throw StorageError.notFound(entity: "Connector", id: connectorId)
        }
        locked { records[connectorId] = Self.withSyncOutcome(existing, at: at, error: syncError) }
    }

    public func delete(connectorId: String) async throws {
        log.record(port: Self.portName, method: "delete(connectorId:)", arguments: [connectorId])
        if let error = failureIfAny(.delete, id: connectorId) {
            throw error
        }
        locked {
            records[connectorId] = nil
            order.removeAll { $0 == connectorId }
        }
    }

    // MARK: - Копии с изменённым полем

    private static func withCursor(_ record: ConnectorRecord, cursor: String?) -> ConnectorRecord {
        ConnectorRecord(
            id: record.id, type: record.type, pluginId: record.pluginId, settingsJson: record.settingsJson,
            keychainNamespace: record.keychainNamespace, selectedCalendarIds: record.selectedCalendarIds,
            isEnabled: record.isEnabled, lastSyncAt: record.lastSyncAt, cursor: cursor, lastError: record.lastError
        )
    }

    private static func withSyncOutcome(_ record: ConnectorRecord, at: Date, error: String?) -> ConnectorRecord {
        ConnectorRecord(
            id: record.id, type: record.type, pluginId: record.pluginId, settingsJson: record.settingsJson,
            keychainNamespace: record.keychainNamespace, selectedCalendarIds: record.selectedCalendarIds,
            isEnabled: record.isEnabled, lastSyncAt: at, cursor: record.cursor, lastError: error
        )
    }
}
