//  InMemoryMeetingRepository+Absorbing — `save(_:absorbing:)`, C-010 v20, правка v22,
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
//  C-010 v22, инвариант 33 (возврат РП на приёмку #134): при непустом `meetingIds`
//  `record.event.id` ОБЯЗАН уже существовать среди сохранённых встреч — `constraintViolation`
//  иначе, ВСЕГДА, независимо от того, есть ли у кого-то из `meetingIds` привязанные
//  `recordings`/`meeting_outputs`. Раньше (v21, до приёмки) отказ здесь срабатывал только
//  когда были такие привязки — так GRDB вело себя естественно, потому что немедленный
//  внешний ключ `meeting_outputs.meeting_id` иначе просто не на что было проверять: без
//  дочерних строк UPDATE в шаге (1) не менял ни одной строки, и вставка отсутствующего
//  победителя на шаге (3) молча создавала бы новую встречу — этого v22 больше не допускает.

import Foundation
import DomainCore

extension InMemoryMeetingRepository {

    /// Подключить каскад инвариантов 7 и 33 (`meeting_outputs`). Зовёт контейнер
    /// `InMemoryRepositories` — единственный вызывающий, наружу поверхности не несёт.
    func attachCascade(meetingOutputs: InMemoryMeetingOutputRepository) {
        self.meetingOutputs = meetingOutputs
    }

    public func save(_ record: MeetingRecord, absorbing meetingIds: [UUID]) async throws {
        // Пустой meetingIds — эквивалент обычного save(_:) не только поведением, но и
        // журналом вызовов: одна запись "save(_:)", не две (возврат РП, приёмка #134).
        guard !meetingIds.isEmpty else {
            try await save(record)
            return
        }
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
        guard !meetingIds.contains(record.event.id) else {
            throw StorageError.constraintViolation(
                message: "save(_:absorbing:): meetingIds не может содержать record.event.id (инвариант 33 C-010 v22)"
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
        // C-010 v22, инвариант 33: при непустом meetingIds победитель обязан уже
        // существовать — безусловно, не только когда есть привязанные recordings/
        // meeting_outputs (возврат РП, приёмка #134).
        let winnerAlreadyExists = locked { records[record.event.id] != nil }
        guard winnerAlreadyExists else {
            throw StorageError.constraintViolation(
                message: "save(_:absorbing:): record.event.id должен существовать среди сохранённых " +
                    "встреч при непустом meetingIds (инвариант 33 C-010 v22)"
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
