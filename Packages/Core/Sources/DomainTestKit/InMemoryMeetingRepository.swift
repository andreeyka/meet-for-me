//  InMemoryMeetingRepository — реализация `MeetingRepository` поверх словаря, C-010
//  §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ИМЯ ВЗЯТО У КОНТРАКТА, А НЕ ПРИДУМАНО: §«Фейк для тестов» C-010 называет восемь
//  реализаций поимённо, и первая из них — `InMemoryMeetingRepository`. Перечисление §6
//  плана MEE-288 говорит «фейки репозиториев C-010» и имён не даёт вовсе.
//
//  ЧТО ЭТОТ ФЕЙК ДЕРЖИТ ИЗ ИНВАРИАНТОВ КОНТРАКТА, названо поимённо, потому что контракт
//  требует «те же инварианты 4—6, 10—13, 17 и 20, чтобы тест на фейке ловил те же ошибки,
//  что тест на настоящей базе», а исполнимы сегодня не все:
//    * инвариант 6 (уникальность `dedup_key`) — ДЕРЖИТСЯ: `save` бросает
//      `constraintViolation`, если тот же ключ уже стоит у ДРУГОГО `meetingId`;
//    * инвариант 30 (уникальность пары `meeting_sources`, C-010 v14) — ДЕРЖИТСЯ: `save`
//      бросает `constraintViolation`, если пара (`sourceConnectorId`, `externalId`) уже
//      стоит у ДРУГОЙ встречи; повторное сохранение той же встречи с той же парой проходит;
//    * инвариант 20 (что бросает `notFound`) — ДЕРЖИТСЯ: `setStatus` на несуществующей
//      встрече бросает, а чтения отдают `nil`;
//    * инварианты 4, 5 (`persons`, `person_emails`), 10—13 — НЕ ДЕРЖАТСЯ ЗДЕСЬ ВОВСЕ: их
//      субъекты — строки таблиц, портов которых в дереве нет (`PersonRepository` и
//      остальные четыре §5 не объявлены, MEE-289);
//    * инвариант 7 (каскад удаления встречи) — С MEE-319 ДЕРЖИТСЯ ЦЕЛИКОМ, по новому
//      устройству C-010 v7: `meeting_sources` и `attendees` живут внутри `MeetingRecord`
//      и уходят вместе с ним; «`recordings.meeting_id` становится `NULL`» держит привязка
//      «запись → встреча» — отдельная от `RecordingManifest.meetingId`, которую заводит
//      и снимает `InMemoryRecordingRepository` (её шапка), а не манифест. Довод, почему
//      это отдельная привязка, а не поле манифеста: манифест (C-002) неизменяем, и
//      обнулить поле в нём можно только СОБРАВ НОВЫЙ МАНИФЕСТ — то есть придумав доменное
//      значение, которого тест не задавал; контракт C-010 v7 инвариант 7 прямо разводит
//      колонку (обнуляется) и `manifest.meetingId` (не обнуляется, устаревает) как два
//      разных факта — прежняя дыра была отсутствием этой привязки, а не ошибкой довода.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА: держимые инварианты здесь суть УСТРОЙСТВО фейка, а не
//  их проверка. Проверяются они тестами `storage`.
//
//  `@unchecked Sendable` с замком, а не актор: `MeetingRepository` объявлен `: Sendable`.

import Foundation
import DomainCore

/// Метод репозитория встреч — адрес заданного тестом отказа.
public enum MeetingRepositoryMethod: String, Sendable, CaseIterable {
    case save
    case meetingById
    case meetingByDedupKey
    case meetingBySource
    case meetings
    case setStatus
    case delete
}

/// Фейк репозитория встреч. Всё поведение задаёт тест.
public final class InMemoryMeetingRepository: MeetingRepository, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "MeetingRepository"

    private let lock = NSLock()
    private let log: PortCallLog

    private var records: [UUID: MeetingRecord] = [:]
    private var order: [UUID] = []
    private var failures: [MeetingRepositoryMethod: (id: String?, error: StorageError)] = [:]
    private var hangingMethods: Set<MeetingRepositoryMethod> = []
    private var hangSeconds: Double = 3600
    private var gatedMethods: Set<MeetingRepositoryMethod> = []
    private var gateContinuations: [MeetingRepositoryMethod: [UUID: CheckedContinuation<Void, Never>]] = [:]

    /// Каскад инварианта 7 (C-010 v7): `delete(meetingIds:)` обнуляет здесь привязку
    /// «запись → встреча» у записей. Ставится контейнером `InMemoryRepositories`; у
    /// одиночного репозитория каскаду уходить некуда, и его нет.
    private weak var recordings: InMemoryRecordingRepository?

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

    /// Положить запись мимо `save`: вход теста, а не вызов порта. В журнал не пишется.
    public func seed(_ list: [MeetingRecord]) {
        locked {
            for record in list {
                if records[record.event.id] == nil {
                    order.append(record.event.id)
                }
                records[record.event.id] = record
            }
        }
    }

    /// Заставить названный метод бросить заданную `StorageError` — в том числе
    /// `dataCorrupted` с заданными `entity`, `id` и `message` (C-010 v2). `id == nil` —
    /// отказ на всяком идентификаторе; иначе только на названном.
    public func fail(with error: StorageError, on method: MeetingRepositoryMethod, id: String? = nil) {
        locked { failures[method] = (id: id, error: error) }
    }

    public func clearFailure(on method: MeetingRepositoryMethod) {
        locked { failures[method] = nil }
    }

    /// Заставить метод НЕ ВЕРНУТЬ управления: он засыпает на `seconds` и только потом
    /// возвращается. На этом стоит К81 (iii) — единственный пункт плана, у которого
    /// ответом служит невозникновение события (условие `Р`).
    public func hang(on method: MeetingRepositoryMethod, seconds: Double = 3600) {
        locked {
            hangingMethods.insert(method)
            hangSeconds = seconds
        }
    }

    public func stopHanging(on method: MeetingRepositoryMethod) {
        locked { _ = hangingMethods.remove(method) }
    }

    /// Ворота с ручным отпуском — в отличие от `hang(on:seconds:)` (фиксированная задержка,
    /// К81 (iii): важен сам факт «не вернулся»), здесь тест управляет МОМЕНТОМ отпуска
    /// явным `release(on:)`, не таймингом. IR-126 (MEE-386, возврат РП, приёмка #105,
    /// 18:55 UTC): доказательство сериализации инв. 11 воротами, а не `hang` с фиксированной
    /// секундой — тот же приём, что `FakeCalendarConnector.hangOrGate`/`release`.
    public func gate(on method: MeetingRepositoryMethod) {
        locked { gatedMethods.insert(method) }
    }

    /// Отпускает все вызовы этого метода, ждущие на воротах. Вызов без ждущих — no-op.
    /// Ворота при этом остаются взведены — следующий вызов того же метода снова встанет
    /// (если нужно освободить его без ожидания, `stopGating(on:)` до его прихода).
    public func release(on method: MeetingRepositoryMethod) {
        let waiting = locked { () -> [CheckedContinuation<Void, Never>] in
            let list = Array((gateContinuations[method] ?? [:]).values)
            gateContinuations[method] = [:]
            return list
        }
        for continuation in waiting { continuation.resume() }
    }

    /// Снимает ворота — последующие вызовы метода больше не встают, уже ждущие не задеты
    /// (их снимает только `release(on:)`). Обычно оба вызываются вместе: `release` отпускает
    /// уже стоящий вызов, `stopGating` — следующий, ещё не пришедший (например, второе
    /// слияние ТОЙ ЖЕ серии, инв. 11 — не нужно вставать в очередь на ворота второй раз).
    public func stopGating(on method: MeetingRepositoryMethod) {
        locked { _ = gatedMethods.remove(method) }
    }

    /// Всё, что лежит в хранилище, в порядке первого появления.
    public var storedRecords: [MeetingRecord] {
        locked { order.compactMap { records[$0] } }
    }

    /// Подключить каскад инварианта 7. Зовёт контейнер `InMemoryRepositories`.
    public func attachCascade(recordings: InMemoryRecordingRepository) {
        self.recordings = recordings
    }

    // MARK: - Оснастка

    private func failureIfAny(_ method: MeetingRepositoryMethod, id: String?) -> StorageError? {
        locked { () -> StorageError? in
            guard let failure = failures[method] else { return nil }
            guard let wanted = failure.id else { return failure.error }
            return wanted == id ? failure.error : nil
        }
    }

    private func hangIfAsked(_ method: MeetingRepositoryMethod) async {
        let (hangs, seconds) = locked { (hangingMethods.contains(method), hangSeconds) }
        guard hangs else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// Возврат РП (приёмка #109, 19:25 UTC): проверка `gatedMethods.contains(method)` и
    /// регистрация continuation были ДВУМЯ отдельными `locked` — между ними `release(on:)`
    /// мог застать словарь ещё пустым (no-op, снимать нечего) и уйти, а континьюация,
    /// зарегистрированная МОМЕНТОМ позже, уже никогда не будет отпущена — то же зависание,
    /// что документировано у К66/К75 (`ControlSurfaceEntryPointsTests.swift`) для
    /// `FakeCalendarConnector.release`. Здесь — одна атомарная проверка-и-регистрация.
    private func waitIfGated(_ method: MeetingRepositoryMethod) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isGated = locked { () -> Bool in
                guard gatedMethods.contains(method) else { return false }
                gateContinuations[method, default: [:]][UUID()] = continuation
                return true
            }
            if !isGated { continuation.resume() }
        }
    }

    // MARK: - MeetingRepository

    /// Инвариант 6 (`dedup_key`) и инвариант 30 (`meeting_sources`, C-010 v14): обе пары
    /// уникальны у ДРУГОЙ встречи — повторное сохранение той же встречи с той же парой
    /// проходит, пара, уже занятая другой, — `constraintViolation`.
    public func save(_ record: MeetingRecord) async throws {
        log.record(port: Self.portName, method: "save(_:)", arguments: [record.event.id.uuidString])
        await hangIfAsked(.save)
        await waitIfGated(.save)
        if let error = failureIfAny(.save, id: record.event.id.uuidString) {
            throw error
        }
        let sources = try Self.sourcesIncludingOwnIdentity(of: record.event, declared: record.sources)
        let dedupClash = locked { () -> Bool in
            guard let key = record.dedupKey else { return false }
            return records.contains { $0.key != record.event.id && $0.value.dedupKey == key }
        }
        if dedupClash {
            throw StorageError.constraintViolation(message: "meetings.dedup_key уникален (инвариант 6 C-010)")
        }
        let sourceClash = locked { () -> Bool in
            records.contains { existingId, existing in
                guard existingId != record.event.id else { return false }
                return existing.sources.contains { existingSource in
                    sources.contains {
                        $0.sourceConnectorId == existingSource.sourceConnectorId
                            && $0.externalId == existingSource.externalId
                    }
                }
            }
        }
        if sourceClash {
            throw StorageError.constraintViolation(
                message: "meeting_sources: пара (source_connector_id, external_id) уникальна (инвариант 30 C-010)"
            )
        }
        locked {
            if records[record.event.id] == nil {
                order.append(record.event.id)
            }
            records[record.event.id] = MeetingRecord(
                event: record.event, dedupKey: record.dedupKey, status: record.status, sources: sources
            )
        }
    }

    /// IR-126 (MEE-372), C-010 v18, инвариант 31 (решение РП, приёмка MEE-384) — то же
    /// правило, дословно, что `GRDBMeetingRepository.sourcesIncludingOwnIdentity`
    /// (`Storage/GRDBMeetingRepositoryWrite.swift`): постановка MEE-384 (п. 6) требует
    /// фейк с тем же поведением. Пустой `declared` — снимок `dropping(event)`; непустой
    /// без identity — `constraintViolation`, ничего не синтезируется.
    private static func sourcesIncludingOwnIdentity(
        of event: MeetingEvent, declared: [MeetingSource]
    ) throws -> [MeetingSource] {
        guard !declared.isEmpty else {
            return [MeetingSource(
                sourceConnectorId: event.sourceConnectorId,
                externalId: event.externalId,
                icalUid: event.icalUid,
                lastModified: event.lastModified,
                payload: MeetingEventPayload(dropping: event)
            )]
        }
        let ownKey = (event.sourceConnectorId, event.externalId)
        guard declared.contains(where: { ($0.sourceConnectorId, $0.externalId) == ownKey }) else {
            throw StorageError.constraintViolation(
                message: "meeting_sources: непустой список источников не содержит " +
                    "собственную идентичность события (инвариант 31 C-010 v18)"
            )
        }
        return declared
    }

    public func meeting(id: UUID) async throws -> MeetingRecord? {
        log.record(port: Self.portName, method: "meeting(id:)", arguments: [id.uuidString])
        await hangIfAsked(.meetingById)
        if let error = failureIfAny(.meetingById, id: id.uuidString) {
            throw error
        }
        return locked { records[id] }
    }

    public func meeting(dedupKey: DedupKey) async throws -> MeetingRecord? {
        log.record(port: Self.portName, method: "meeting(dedupKey:)", arguments: [String(describing: dedupKey)])
        await hangIfAsked(.meetingByDedupKey)
        if let error = failureIfAny(.meetingByDedupKey, id: nil) {
            throw error
        }
        return locked { order.compactMap { records[$0] }.first { $0.dedupKey == dedupKey } }
    }

    /// C-010 v10, IR-118 (MEE-348), инвариант 30: пара — первичный ключ `meeting_sources`
    /// (§1), результат не более чем один.
    public func meeting(sourceConnectorId: String, externalId: String) async throws -> MeetingRecord? {
        log.record(
            port: Self.portName, method: "meeting(sourceConnectorId:externalId:)",
            arguments: [sourceConnectorId, externalId]
        )
        await hangIfAsked(.meetingBySource)
        if let error = failureIfAny(.meetingBySource, id: nil) {
            throw error
        }
        return locked {
            order.compactMap { records[$0] }.first { record in
                record.sources.contains {
                    $0.sourceConnectorId == sourceConnectorId && $0.externalId == externalId
                }
            }
        }
    }

    public func meetings(from: Date, to: Date) async throws -> [MeetingRecord] {
        log.record(
            port: Self.portName,
            method: "meetings(from:to:)",
            arguments: [String(from.timeIntervalSince1970), String(to.timeIntervalSince1970)]
        )
        await hangIfAsked(.meetings)
        if let error = failureIfAny(.meetings, id: nil) {
            throw error
        }
        return locked {
            order
                .compactMap { records[$0] }
                .filter { from <= $0.event.start && $0.event.start < to }
        }
    }

    public func setStatus(_ status: MeetingStatus, meetingId: UUID) async throws {
        log.record(
            port: Self.portName,
            method: "setStatus(_:meetingId:)",
            arguments: [status.rawValue, meetingId.uuidString]
        )
        await hangIfAsked(.setStatus)
        if let error = failureIfAny(.setStatus, id: meetingId.uuidString) {
            throw error
        }
        let existing = locked { records[meetingId] }
        guard let existing else {
            throw StorageError.notFound(entity: "meetings", id: meetingId.uuidString)
        }
        let updated = MeetingRecord(
            event: existing.event,
            dedupKey: existing.dedupKey,
            status: status,
            sources: existing.sources
        )
        locked { records[meetingId] = updated }
    }

    public func delete(meetingIds: [UUID]) async throws {
        log.record(
            port: Self.portName,
            method: "delete(meetingIds:)",
            arguments: meetingIds.map(\.uuidString)
        )
        await hangIfAsked(.delete)
        if let error = failureIfAny(.delete, id: meetingIds.first?.uuidString) {
            throw error
        }
        locked {
            for identifier in meetingIds {
                records[identifier] = nil
            }
            order.removeAll { !records.keys.contains($0) }
        }
        // Инвариант 7: колонка `recordings.meeting_id` обнуляется каскадом;
        // `manifest.meetingId` не трогается и может остаться устаревшим (§6 C-010 v7).
        recordings?.detachFromDeletedMeetings(Set(meetingIds))
    }
}
