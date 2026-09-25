//  InMemoryMeetingRepository+Absorbing — `save(_:absorbing:)`, C-010 v20, правка v21,
//  IR-133 (MEE-405), инвариант 33. Деление по объёму, не по смыслу — тот же приём, что
//  `GRDBMeetingRepositoryWrite.swift`/`SpeakerAttribution+*.swift`: тело класса в одном
//  файле превышало `type_body_length`/`file_length` SwiftLint (--strict, «Core + Mac»).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  ПОРЯДОК ШАГОВ — тот же, что `GRDBMeetingRepositoryWrite.save(_:absorbing:)`: перенос
//  привязок `recordings`/`meeting_outputs` на победителя, удаление `meetingIds` (тот же
//  каскад, что `delete(meetingIds:)`), тело `save(_:)` — уникальность `dedup_key`/пары
//  источника проверяется ПОСЛЕ удаления. Это то, что позволяет победителю унаследовать
//  `dedup_key` проигравшего без ложной коллизии с самим собой — ровно случай слияния,
//  ради которого метод заведён (решает коллизию признаков (а)/(б) правила слияния C-005).
//
//  ФЕЙК — НЕ ТРАНЗАКЦИЯ: атомарность здесь устроена проверкой ВСЕХ условий отказа
//  (`validateAbsorbing`) ДО первой мутации состояния (`commitAbsorbing`), а не откатом уже
//  применённых изменений, как у настоящей БД. Наблюдаемый исход тот же: отказ на любом
//  условии не переносит ни одной привязки и не меняет ни одной записи.
//
//  СТРОКА (открытый вопрос v22, возврат РП на постановку, шапка
//  `GRDBMeetingRepositoryWrite.swift`): если `record.event.id` ещё не встречается среди
//  сохранённых встреч, а у кого-то из `meetingIds` есть привязанные `recordings`/
//  `meeting_outputs`, GRDB упирается во внешний ключ (немедленный, `PRAGMA foreign_keys =
//  ON`, §2 контракта) раньше, чем шаг (3) вставит строку победителя. Фейк не эталон
//  поведения БД, но не должен быть слабее его — тот же исход воспроизведён здесь явно
//  через `isBound(toAnyOf:)` обоих каскадных фейков, тем же `constraintViolation`.
//  Архитектор решает окончательное поведение в v22, не эта задача.

import Foundation
import DomainCore

extension InMemoryMeetingRepository {

    /// Подключить каскад инвариантов 7 и 33 (`meeting_outputs`). Зовёт контейнер
    /// `InMemoryRepositories`.
    public func attachCascade(meetingOutputs: InMemoryMeetingOutputRepository) {
        self.meetingOutputs = meetingOutputs
    }

    public func save(_ record: MeetingRecord, absorbing meetingIds: [UUID]) async throws {
        log.record(
            port: Self.portName,
            method: "save(_:absorbing:)",
            arguments: [record.event.id.uuidString] + meetingIds.map(\.uuidString)
        )
        await hangIfAsked(.save)
        await waitIfGated(.save)
        if let error = failureIfAny(.save, id: record.event.id.uuidString) {
            throw error
        }
        guard !meetingIds.isEmpty else {
            try await save(record)
            return
        }
        guard !meetingIds.contains(record.event.id) else {
            throw StorageError.constraintViolation(
                message: "save(_:absorbing:): meetingIds не может содержать record.event.id (инвариант 33 C-010 v21)"
            )
        }
        let losing = Set(meetingIds)
        let sources = try validateAbsorbing(record: record, losing: losing)
        recordings?.reassignFromDeletedMeetings(losing, to: record.event.id)
        meetingOutputs?.reassignFromDeletedMeetings(losing, to: record.event.id)
        commitAbsorbing(record: record, sources: sources, meetingIds: meetingIds)
    }

    /// Все условия отказа шагов (1)-(3), проверенные ДО первой мутации состояния —
    /// возвращает источники победителя (инвариант 31), готовые к записи `commitAbsorbing`.
    private func validateAbsorbing(record: MeetingRecord, losing: Set<UUID>) throws -> [MeetingSource] {
        let winnerAlreadyExists = locked { records[record.event.id] != nil }
        let hasAttachedChildRows = (recordings?.isBound(toAnyOf: losing) ?? false)
            || (meetingOutputs?.isBound(toAnyOf: losing) ?? false)
        guard winnerAlreadyExists || !hasAttachedChildRows else {
            throw StorageError.constraintViolation(
                message: "recordings/meeting_outputs: перенос на ещё не существующую встречу " +
                    "нарушает внешний ключ (тот же отказ, что у GRDB при немедленных внешних ключах)"
            )
        }
        let sources = try Self.sourcesIncludingOwnIdentity(of: record.event, declared: record.sources)
        let dedupClash = locked { () -> Bool in
            guard let key = record.dedupKey else { return false }
            return records.contains {
                $0.key != record.event.id && !losing.contains($0.key) && $0.value.dedupKey == key
            }
        }
        if dedupClash {
            throw StorageError.constraintViolation(message: "meetings.dedup_key уникален (инвариант 6 C-010)")
        }
        let sourceClash = locked { () -> Bool in
            records.contains { existingId, existing in
                guard existingId != record.event.id, !losing.contains(existingId) else { return false }
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
        return sources
    }

    /// Шаги (2)+(3): удаляет `meetingIds` из хранилища и пишет `record` — ничего не
    /// проверяет, вызывается только после того, как `validateAbsorbing` прошла целиком.
    private func commitAbsorbing(record: MeetingRecord, sources: [MeetingSource], meetingIds: [UUID]) {
        locked {
            for identifier in meetingIds {
                records[identifier] = nil
            }
            order.removeAll { !records.keys.contains($0) }
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
}
