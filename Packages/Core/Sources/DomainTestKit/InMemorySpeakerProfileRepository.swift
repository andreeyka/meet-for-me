//  InMemorySpeakerProfileRepository — реализация `SpeakerProfileRepository` поверх словаря,
//  C-010 §«Фейк для тестов». Имя взято у контракта.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ЧТО ДЕРЖИТСЯ ИЗ ИНВАРИАНТОВ (МЕЕ-189, К48, действующая редакция):
//    * инвариант 11 — «`speaker_profiles.embedding` имеет длину ровно `embedding_dim * 4`
//      байта» — ДЕРЖИТСЯ БЕЗ ЕДИНОЙ СТРОКИ ЗДЕСЬ, тем же классом замера, что инвариант 13
//      у `InMemoryRecordingRepository` (его шапка): `SpeakerProfile.embedding` объявлен
//      `[Float]`, а `Float` — ровно 4 байта; для всякого значения этого типа число байт при
//      кодировании равно `count * 4` по построению языка, и написать `[Float]`, нарушающий
//      это, нечем — значения, которое ловило бы нарушение, не существует;
//    * инвариант 20 — чтения отдают `nil`/пустой массив. `notFound` этот порт не бросает
//      НИ ОДНИМ методом: ни один метод `SpeakerProfileRepository` не входит в закрытый
//      список инварианта 20 («…бросается только методами… `setStatus`, `rename`, `setMe`,
//      `setCursor`, `setSyncOutcome`, `markUserEdited`, `updateSegmentText`») — `upsert`,
//      `delete` и `deleteAll` в него не входят и потому отказом на отсутствующей строке
//      не отвечают: `delete`/`deleteAll` на отсутствующем ключе — операция без эффекта.
//
//  КЛЮЧ — ПАРА (`personId`, `modelVersion`), А НЕ ОДИН `personId`: `profile(personId:
//  modelVersion:)` берёт оба параметра, `deleteAll(modelVersion:)` снимает профили одной
//  версии у ВСЕХ людей, а `delete(personId:)` — все версии одного человека; это два разных
//  среза одного и того же хранилища, и оба нужны отдельно.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА.

import Foundation
import DomainCore

/// Метод репозитория голосовых профилей — адрес заданного тестом отказа (К47).
public enum SpeakerProfileRepositoryMethod: String, Sendable, CaseIterable {
    case profile
    case profiles
    case upsert
    case delete
    case deleteAll
}

private struct SpeakerProfileKey: Hashable {
    let personId: UUID
    let modelVersion: String
}

/// Фейк репозитория голосовых профилей. Всё поведение задаёт тест.
public final class InMemorySpeakerProfileRepository: SpeakerProfileRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "SpeakerProfileRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var records: [SpeakerProfileKey: SpeakerProfile] = [:]
    private var order: [SpeakerProfileKey] = []
    private var failures: [SpeakerProfileRepositoryMethod: (id: String?, error: StorageError)] = [:]

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

    /// Положить профили мимо `upsert`: вход теста, а не вызов порта. В журнал не пишется.
    public func seed(_ list: [SpeakerProfile]) {
        locked {
            for profile in list {
                let key = SpeakerProfileKey(personId: profile.personId, modelVersion: profile.modelVersion)
                if records[key] == nil {
                    order.append(key)
                }
                records[key] = profile
            }
        }
    }

    public func fail(with error: StorageError, on method: SpeakerProfileRepositoryMethod, id: String? = nil) {
        locked { failures[method] = (id: id, error: error) }
    }

    public func clearFailure(on method: SpeakerProfileRepositoryMethod) {
        locked { failures[method] = nil }
    }

    /// Всё, что лежит в хранилище, в порядке первого появления.
    public var storedProfiles: [SpeakerProfile] {
        locked { order.compactMap { records[$0] } }
    }

    // MARK: - Оснастка

    private func failureIfAny(_ method: SpeakerProfileRepositoryMethod, id: String?) -> StorageError? {
        locked { () -> StorageError? in
            guard let failure = failures[method] else { return nil }
            guard let wanted = failure.id else { return failure.error }
            return wanted == id ? failure.error : nil
        }
    }

    // MARK: - SpeakerProfileRepository

    public func profile(personId: UUID, modelVersion: String) async throws -> SpeakerProfile? {
        log.record(
            port: Self.portName, method: "profile(personId:modelVersion:)",
            arguments: [personId.uuidString, modelVersion]
        )
        if let error = failureIfAny(.profile, id: personId.uuidString) {
            throw error
        }
        return locked { records[SpeakerProfileKey(personId: personId, modelVersion: modelVersion)] }
    }

    public func profiles(personIds: [UUID], modelVersion: String) async throws -> [SpeakerProfile] {
        log.record(
            port: Self.portName, method: "profiles(personIds:modelVersion:)",
            arguments: personIds.map(\.uuidString) + [modelVersion]
        )
        if let error = failureIfAny(.profiles, id: nil) {
            throw error
        }
        let wanted = Set(personIds)
        return locked {
            order
                .filter { $0.modelVersion == modelVersion && wanted.contains($0.personId) }
                .compactMap { records[$0] }
        }
    }

    public func upsert(_ profile: SpeakerProfile) async throws {
        log.record(
            port: Self.portName, method: "upsert(_:)",
            arguments: [profile.personId.uuidString, profile.modelVersion]
        )
        if let error = failureIfAny(.upsert, id: profile.personId.uuidString) {
            throw error
        }
        let key = SpeakerProfileKey(personId: profile.personId, modelVersion: profile.modelVersion)
        locked {
            if records[key] == nil {
                order.append(key)
            }
            records[key] = profile
        }
    }

    public func delete(personId: UUID) async throws {
        log.record(port: Self.portName, method: "delete(personId:)", arguments: [personId.uuidString])
        if let error = failureIfAny(.delete, id: personId.uuidString) {
            throw error
        }
        locked {
            let doomed = order.filter { $0.personId == personId }
            for key in doomed {
                records[key] = nil
            }
            order.removeAll { $0.personId == personId }
        }
    }

    public func deleteAll(modelVersion: String) async throws {
        log.record(port: Self.portName, method: "deleteAll(modelVersion:)", arguments: [modelVersion])
        if let error = failureIfAny(.deleteAll, id: nil) {
            throw error
        }
        locked {
            let doomed = order.filter { $0.modelVersion == modelVersion }
            for key in doomed {
                records[key] = nil
            }
            order.removeAll { $0.modelVersion == modelVersion }
        }
    }
}
