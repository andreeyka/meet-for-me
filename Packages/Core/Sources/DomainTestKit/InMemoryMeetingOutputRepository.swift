//  InMemoryMeetingOutputRepository — реализация `MeetingOutputRepository` поверх словаря,
//  C-010 §«Фейк для тестов». Имя взято у контракта.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ЧТО ДЕРЖИТСЯ ИЗ ИНВАРИАНТОВ (МЕЕ-189, К48, действующая редакция):
//    * инвариант 20 — чтения отдают пустой массив. `notFound` бросает РОВНО ОДИН метод —
//      `markUserEdited` — он и только он входит в закрытый список инварианта 20
//      («…бросается только методами… `markUserEdited`…»); `save` в список не входит.
//
//  `markUserEdited` СТАВИТ `isUserEdited = true` — имя метода не оставляет другого чтения:
//  «пометить правкой человека» без установки самого признака было бы методом без эффекта.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА.

import Foundation
import DomainCore

/// Метод репозитория выдач саммари — адрес заданного тестом отказа (К47).
public enum MeetingOutputRepositoryMethod: String, Sendable, CaseIterable {
    case outputs
    case save
    case markUserEdited
}

/// Фейк репозитория выдач саммари. Всё поведение задаёт тест.
public final class InMemoryMeetingOutputRepository: MeetingOutputRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "MeetingOutputRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var records: [UUID: MeetingOutput] = [:]
    private var order: [UUID] = []
    private var failures: [MeetingOutputRepositoryMethod: (id: String?, error: StorageError)] = [:]

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

    /// Положить выдачи мимо `save`: вход теста, а не вызов порта. В журнал не пишется.
    public func seed(_ list: [MeetingOutput]) {
        locked {
            for output in list {
                if records[output.id] == nil {
                    order.append(output.id)
                }
                records[output.id] = output
            }
        }
    }

    public func fail(with error: StorageError, on method: MeetingOutputRepositoryMethod, id: String? = nil) {
        locked { failures[method] = (id: id, error: error) }
    }

    public func clearFailure(on method: MeetingOutputRepositoryMethod) {
        locked { failures[method] = nil }
    }

    /// Всё, что лежит в хранилище, в порядке первого появления.
    public var storedRecords: [MeetingOutput] {
        locked { order.compactMap { records[$0] } }
    }

    // MARK: - Оснастка

    private func failureIfAny(_ method: MeetingOutputRepositoryMethod, id: String?) -> StorageError? {
        locked { () -> StorageError? in
            guard let failure = failures[method] else { return nil }
            guard let wanted = failure.id else { return failure.error }
            return wanted == id ? failure.error : nil
        }
    }

    // MARK: - MeetingOutputRepository

    public func outputs(meetingId: UUID) async throws -> [MeetingOutput] {
        log.record(port: Self.portName, method: "outputs(meetingId:)", arguments: [meetingId.uuidString])
        if let error = failureIfAny(.outputs, id: meetingId.uuidString) {
            throw error
        }
        return locked { order.compactMap { records[$0] }.filter { $0.meetingId == meetingId } }
    }

    public func save(_ output: MeetingOutput) async throws {
        log.record(port: Self.portName, method: "save(_:)", arguments: [output.id.uuidString])
        if let error = failureIfAny(.save, id: output.id.uuidString) {
            throw error
        }
        locked {
            if records[output.id] == nil {
                order.append(output.id)
            }
            records[output.id] = output
        }
    }

    public func markUserEdited(outputId: UUID, contentMarkdown: String) async throws {
        log.record(
            port: Self.portName, method: "markUserEdited(outputId:contentMarkdown:)",
            arguments: [outputId.uuidString]
        )
        if let error = failureIfAny(.markUserEdited, id: outputId.uuidString) {
            throw error
        }
        let existing = locked { records[outputId] }
        guard let existing else {
            throw StorageError.notFound(entity: "MeetingOutput", id: outputId.uuidString)
        }
        locked {
            records[outputId] = MeetingOutput(
                id: existing.id, meetingId: existing.meetingId, kind: existing.kind, engine: existing.engine,
                modelVersion: existing.modelVersion, promptVersion: existing.promptVersion,
                contentMarkdown: contentMarkdown, structuredJson: existing.structuredJson,
                createdAt: existing.createdAt, isUserEdited: true
            )
        }
    }
}
