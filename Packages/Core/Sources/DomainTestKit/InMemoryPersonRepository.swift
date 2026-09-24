//  InMemoryPersonRepository — реализация `PersonRepository` поверх словаря, C-010
//  §«Фейк для тестов». Имя взято у контракта.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ЧТО ДЕРЖИТСЯ ИЗ ИНВАРИАНТОВ, названо поимённо (МЕЕ-189, К48, действующая редакция —
//  дельта К MEE-189): «фейки держат инварианты 4—6, 10—13, 17, 20, 28 и 29» — в СВОЕЙ
//  части, здесь это:
//    * инвариант 4 — не более одной строки с `is_me = 1`: `setMe` снимает флаг со всех
//      прочих прежде, чем ставит его на заданного;
//    * инвариант 5 — `person_emails.email` уникален по всей таблице (регистр нормализован,
//      К8): держится через словарь «нормализованный email → владелец»;
//    * инвариант 20 — чтения отдают `nil`/пустой массив; `notFound` бросают только
//      `rename` и `setMe` — ровно они входят в закрытый список инварианта 20
//      («…бросается только методами, которые обязаны изменить существующую строку
//      (`setStatus`, `rename`, `setMe`, `setCursor`, `setSyncOutcome`, `markUserEdited`,
//      `updateSegmentText`)»); `upsert` и `addNameForms` в списке не значатся и не бросают.
//
//  СТРОКА: семантика `upsert(displayName:emails:)`, когда поданный e-mail уже принадлежит
//  ДРУГОМУ человеку, — контракт (К8) сам называет два законных исхода дословно: «второе
//  назначение либо переносит адрес и оставляет одну строку, либо даёт `constraintViolation`»
//  — решение оставлено реализатору порта, а не мне (§8 «Фейк для тестов» этого решения не
//  называет). Беру (а) «перенос»: `upsert` разрешает владельца по каждому поданному email —
//  если все совпадения указывают на ОДНОГО существующего человека, запись обновляется
//  (имя заменяется, адреса добавляются); если адреса не совпали ни с кем — заводится новый
//  человек; если совпадения указывают на РАЗНЫХ существующих людей — `constraintViolation`
//  (слить две строки `upsert` не может, второго метода для этого контракт не даёт). Довод
//  выбора (а), а не (б) «безусловный отказ»: без разрешения владельца по email `upsert` не
//  умел бы обновлять уже существующую запись по имени того же человека — единственный ключ
//  входа у метода это email, и (б) сделал бы повторный `upsert` того же человека неотличимым
//  от столкновения с чужим. Цена (а): второй вызов с чужим email молча меняет `displayName`
//  существующей записи, а не заводит новую, — так и написано «перенос».
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА: держимые инварианты здесь суть УСТРОЙСТВО фейка, а не
//  их проверка. Проверяются они тестами `storage`.
//
//  `@unchecked Sendable` с замком, а не актор: `PersonRepository` объявлен `: Sendable`.

import Foundation
import DomainCore

/// Метод репозитория персон — адрес заданного тестом отказа (К47).
public enum PersonRepositoryMethod: String, Sendable, CaseIterable {
    case upsert
    case personById
    case personByEmail
    case persons
    case rename
    case setMe
    case me
    case addNameForms
    case nameForms
}

/// Фейк репозитория персон. Всё поведение задаёт тест.
public final class InMemoryPersonRepository: PersonRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "PersonRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var records: [UUID: PersonRecord] = [:]
    private var order: [UUID] = []
    /// Инвариант 5: нормализованный (нижний регистр) email → владелец. Один email — один человек.
    private var emailOwner: [String: UUID] = [:]
    private var nameFormsByPerson: [UUID: [NameForm]] = [:]
    private var failures: [PersonRepositoryMethod: (id: String?, error: StorageError)] = [:]

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

    /// Положить запись мимо `upsert`: вход теста, а не вызов порта. В журнал не пишется,
    /// инвариант 5 при этом НЕ проверяется — вход теста не связан ничем, как и `seed`
    /// у соседних фейков.
    public func seed(_ list: [PersonRecord]) {
        locked {
            for record in list {
                if records[record.id] == nil {
                    order.append(record.id)
                }
                records[record.id] = record
                for email in record.emails {
                    emailOwner[email.lowercased()] = record.id
                }
            }
        }
    }

    public func fail(with error: StorageError, on method: PersonRepositoryMethod, id: String? = nil) {
        locked { failures[method] = (id: id, error: error) }
    }

    public func clearFailure(on method: PersonRepositoryMethod) {
        locked { failures[method] = nil }
    }

    /// Всё, что лежит в хранилище, в порядке первого появления.
    public var storedRecords: [PersonRecord] {
        locked { order.compactMap { records[$0] } }
    }

    // MARK: - Оснастка

    private func failureIfAny(_ method: PersonRepositoryMethod, id: String?) -> StorageError? {
        locked { () -> StorageError? in
            guard let failure = failures[method] else { return nil }
            guard let wanted = failure.id else { return failure.error }
            return wanted == id ? failure.error : nil
        }
    }

    // MARK: - PersonRepository

    public func upsert(displayName: String, emails: [String]) async throws -> UUID {
        log.record(port: Self.portName, method: "upsert(displayName:emails:)", arguments: [displayName])
        if let error = failureIfAny(.upsert, id: nil) {
            throw error
        }
        let normalized = emails.map { $0.lowercased() }
        let outcome = locked { () -> UUID? in
            let owners = Set(normalized.compactMap { emailOwner[$0] })
            guard owners.count <= 1 else { return nil }
            let identifier = owners.first ?? UUID()
            if records[identifier] == nil {
                order.append(identifier)
            }
            let existing = records[identifier]
            // Адреса ДОБАВЛЯЮТСЯ, а не заменяются (шапка файла: «адреса добавляются»,
            // возврат по приёмке MEE-320) — иначе адрес, унесённый предыдущим `upsert`,
            // остаётся ключом в `emailOwner`, а `person(email:)` находит запись, из чьих
            // `emails` он уже пропал. Существующий список — первым, новые — следом, без
            // дублей; порядок стабилен между вызовами.
            let existingEmails = existing?.emails ?? []
            let mergedEmails = existingEmails + normalized.filter { !existingEmails.contains($0) }
            let wasMe = existing?.isMe ?? false
            records[identifier] = PersonRecord(
                id: identifier, displayName: displayName, emails: mergedEmails, isMe: wasMe
            )
            for email in normalized {
                emailOwner[email] = identifier
            }
            return identifier
        }
        guard let identifier = outcome else {
            throw StorageError.constraintViolation(
                message: "person_emails.email уникален (инвариант 5 C-010): адреса принадлежат разным людям"
            )
        }
        return identifier
    }

    public func person(id: UUID) async throws -> PersonRecord? {
        log.record(port: Self.portName, method: "person(id:)", arguments: [id.uuidString])
        if let error = failureIfAny(.personById, id: id.uuidString) {
            throw error
        }
        return locked { records[id] }
    }

    public func person(email: String) async throws -> PersonRecord? {
        let normalized = email.lowercased()
        log.record(port: Self.portName, method: "person(email:)", arguments: [normalized])
        if let error = failureIfAny(.personByEmail, id: normalized) {
            throw error
        }
        return locked { emailOwner[normalized].flatMap { records[$0] } }
    }

    public func persons(ids: [UUID]) async throws -> [PersonRecord] {
        log.record(port: Self.portName, method: "persons(ids:)", arguments: ids.map(\.uuidString))
        if let error = failureIfAny(.persons, id: nil) {
            throw error
        }
        let wanted = Set(ids)
        return locked { order.compactMap { records[$0] }.filter { wanted.contains($0.id) } }
    }

    public func rename(personId: UUID, displayName: String) async throws {
        log.record(
            port: Self.portName, method: "rename(personId:displayName:)",
            arguments: [personId.uuidString, displayName]
        )
        if let error = failureIfAny(.rename, id: personId.uuidString) {
            throw error
        }
        let existing = locked { records[personId] }
        guard let existing else {
            throw StorageError.notFound(entity: "Person", id: personId.uuidString)
        }
        locked {
            records[personId] = PersonRecord(
                id: existing.id, displayName: displayName, emails: existing.emails, isMe: existing.isMe
            )
        }
    }

    public func setMe(personId: UUID) async throws {
        log.record(port: Self.portName, method: "setMe(personId:)", arguments: [personId.uuidString])
        if let error = failureIfAny(.setMe, id: personId.uuidString) {
            throw error
        }
        let existing = locked { records[personId] }
        guard let existing else {
            throw StorageError.notFound(entity: "Person", id: personId.uuidString)
        }
        // Инвариант 4: снять флаг со всех прочих, прежде чем поставить его на заданного.
        locked {
            for (identifier, record) in records where record.isMe && identifier != personId {
                records[identifier] = PersonRecord(
                    id: record.id, displayName: record.displayName, emails: record.emails, isMe: false
                )
            }
            records[personId] = PersonRecord(
                id: existing.id, displayName: existing.displayName, emails: existing.emails, isMe: true
            )
        }
    }

    public func me() async throws -> PersonRecord? {
        log.record(port: Self.portName, method: "me()")
        if let error = failureIfAny(.me, id: nil) {
            throw error
        }
        return locked { order.compactMap { records[$0] }.first { $0.isMe } }
    }

    public func addNameForms(_ forms: [NameForm]) async throws {
        log.record(port: Self.portName, method: "addNameForms(_:)", arguments: forms.map(\.form))
        if let error = failureIfAny(.addNameForms, id: nil) {
            throw error
        }
        locked {
            for form in forms {
                nameFormsByPerson[form.personId, default: []].append(form)
            }
        }
    }

    public func nameForms(personIds: [UUID]) async throws -> [NameForm] {
        log.record(port: Self.portName, method: "nameForms(personIds:)", arguments: personIds.map(\.uuidString))
        if let error = failureIfAny(.nameForms, id: nil) {
            throw error
        }
        let wanted = Set(personIds)
        return locked {
            order
                .filter { wanted.contains($0) }
                .flatMap { nameFormsByPerson[$0] ?? [] }
        }
    }
}
