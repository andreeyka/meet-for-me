//  InMemoryRecordingRepository — реализация `RecordingRepository` поверх словаря, C-010
//  §«Фейк для тестов». Имя взято у контракта.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ЧТО ДЕРЖИТСЯ ИЗ ИНВАРИАНТОВ, названо поимённо:
//    * инвариант 13 — `directory_name` уникален и равен `UUID.uuidString` записи — ДЕРЖИТСЯ
//      БЕЗ ЕДИНОЙ СТРОКИ ЗДЕСЬ, и это замер, а не рассуждение. Первую половину держит сам тип:
//      `RecordingManifest.validate()` проверяет `directoryName == recordingId.uuidString`
//      (C-002, инвариант 7), и значения, нарушающего её, не существует — собрать его нечем.
//      Вторую держит устройство хранилища: записи лежат словарём по `recordingId`, а имя
//      каталога есть функция от него, значит два разных имени у одного ключа невозможны.
//      Проверка в `save` была написана и СНЯТА: она недостижима ни на одном входе, то есть
//      зелена по построению (правило 7 проекта). Замер — вектором в `InMemoryRepositoriesTests`;
//    * инвариант 14 — файлов на диске фейк не трогает вовсе: их у него нет;
//    * инвариант 20 — чтения отдают `nil` и пустой массив, `notFound` не бросает ни одно
//      из них; у этого порта методов, обязанных изменить существующую строку, нет.
//
//  ПРЕДИКАТ `unfinalized()` НАЗВАН ЯВНО, потому что контракт его не определяет: запись
//  входит в ответ тогда и только тогда, когда её `RecordingStatus` НЕ РАВЕН `.finalized`.
//  Имя читается буквально, и на этом чтении сходится К77: его вход — «хранилище с записью
//  в КАЖДОМ значении `RecordingStatus`», а ответ разбирает `.recording`/`.stopping` (зовём
//  `recover`), `.failed` (сессии не заводим) и `.finalized` (в `unfinalized()` не попадает
//  вовсе). Предикат «не `.finalized`» отдаёт ровно первые три. Это решение фейка, а не
//  утверждение о порте.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА.

import Foundation
import DomainCore

/// Метод репозитория записей — адрес заданного тестом отказа.
public enum RecordingRepositoryMethod: String, Sendable, CaseIterable {
    case save
    case recordingById
    case recordingsByMeeting
    case unfinalized
    case delete
}

/// Фейк репозитория записей. Всё поведение задаёт тест.
public final class InMemoryRecordingRepository: RecordingRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "RecordingRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var records: [UUID: RecordingRecord] = [:]
    private var order: [UUID] = []
    private var failures: [RecordingRepositoryMethod: (id: String?, error: StorageError)] = [:]
    private var deletedDirectories: [String] = []

    /// Каскад по инварианту 8: удаление записи уносит её транскрипты. Ставится контейнером
    /// `InMemoryRepositories`; у одиночного репозитория каскаду уходить некуда, и его нет.
    private weak var transcripts: InMemoryTranscriptRepository?

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

    /// Положить записи мимо `save`: вход теста, а не вызов порта. В журнал не пишется,
    /// инвариант 13 при этом НЕ проверяется — вход теста не связан ничем.
    public func seed(_ list: [RecordingRecord]) {
        locked {
            for record in list {
                let identifier = record.manifest.recordingId
                if records[identifier] == nil {
                    order.append(identifier)
                }
                records[identifier] = record
            }
        }
    }

    public func fail(with error: StorageError, on method: RecordingRepositoryMethod, id: String? = nil) {
        locked { failures[method] = (id: id, error: error) }
    }

    public func clearFailure(on method: RecordingRepositoryMethod) {
        locked { failures[method] = nil }
    }

    /// Каталоги, которые `delete(recordingId:deleteFiles: true)` объявил удалёнными.
    /// Файлов у фейка нет; это НАБЛЮДАЕМОСТЬ намерения, а не запись об удалении с диска.
    public var directoriesAskedToDelete: [String] {
        locked { deletedDirectories }
    }

    public var storedRecords: [RecordingRecord] {
        locked { order.compactMap { records[$0] } }
    }

    /// Подключить каскад инварианта 8. Зовёт контейнер `InMemoryRepositories`.
    public func attachCascade(transcripts: InMemoryTranscriptRepository) {
        self.transcripts = transcripts
    }

    // MARK: - Оснастка

    private func failureIfAny(_ method: RecordingRepositoryMethod, id: String?) -> StorageError? {
        locked { () -> StorageError? in
            guard let failure = failures[method] else { return nil }
            guard let wanted = failure.id else { return failure.error }
            return wanted == id ? failure.error : nil
        }
    }

    // MARK: - RecordingRepository

    public func save(_ record: RecordingRecord) async throws {
        let identifier = record.manifest.recordingId
        log.record(
            port: Self.portName,
            method: "save(_:)",
            arguments: [identifier.uuidString, record.status.rawValue]
        )
        if let error = failureIfAny(.save, id: identifier.uuidString) {
            throw error
        }
        locked {
            if records[identifier] == nil {
                order.append(identifier)
            }
            records[identifier] = record
        }
    }

    public func recording(id: UUID) async throws -> RecordingRecord? {
        log.record(port: Self.portName, method: "recording(id:)", arguments: [id.uuidString])
        if let error = failureIfAny(.recordingById, id: id.uuidString) {
            throw error
        }
        return locked { records[id] }
    }

    public func recordings(meetingId: UUID) async throws -> [RecordingRecord] {
        log.record(port: Self.portName, method: "recordings(meetingId:)", arguments: [meetingId.uuidString])
        if let error = failureIfAny(.recordingsByMeeting, id: meetingId.uuidString) {
            throw error
        }
        return locked {
            order
                .compactMap { records[$0] }
                .filter { $0.manifest.meetingId == meetingId }
        }
    }

    public func unfinalized() async throws -> [RecordingRecord] {
        log.record(port: Self.portName, method: "unfinalized()")
        if let error = failureIfAny(.unfinalized, id: nil) {
            throw error
        }
        return locked {
            order
                .compactMap { records[$0] }
                .filter { $0.status != .finalized }
        }
    }

    public func delete(recordingId: UUID, deleteFiles: Bool) async throws {
        log.record(
            port: Self.portName,
            method: "delete(recordingId:deleteFiles:)",
            arguments: [recordingId.uuidString, String(deleteFiles)]
        )
        if let error = failureIfAny(.delete, id: recordingId.uuidString) {
            throw error
        }
        let removed = locked { () -> RecordingRecord? in
            let taken = records.removeValue(forKey: recordingId)
            order.removeAll { $0 == recordingId }
            return taken
        }
        if deleteFiles, let removed {
            locked { deletedDirectories.append(removed.manifest.directoryName) }
        }
        // Инвариант 8: удаление записи каскадно уносит её транскрипты, а те — сегменты.
        transcripts?.cascadeDelete(recordingId: recordingId)
    }
}
