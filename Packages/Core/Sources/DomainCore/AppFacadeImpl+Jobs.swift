//  AppFacadeImpl — команды обработки и чтение задач, группа Н плана MEE-410 (C-016 v11,
//  MEE-25; К37, К38, К65, строки `jobs.*` К27 перечня MEE-401; задачи MEE-420, MEE-465).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧТО НАЗВАНО КОНТРАКТОМ.
//   • Инв. 12 (правка IR-144, MEE-463): `retranscribe` сначала читает запись
//     `RecordingRepository.recording(id:)` (C-010): записи нет — `notFound(entity: "Recording",
//     id:)`; запись не `.finalized` — `notAllowed(reason:)`. Порядок значим: запись раньше
//     профиля. Затем — профиль: не хватает моделей — `profileNotReady(profileId:
//     missingModelIds:)` (недостающие называет `ModelCatalogPort.missingModels(profileId:)`,
//     C-014 инв. 10). Ни в одном отказе задача не ставится. Подача —
//     `JobSubmission.standard(_:runAfter:)` (таблица §4 C-013) для `transcribe` с
//     `language: nil` (язык даёт профиль, C-014 §3) и правилом «только от сети» из действующих
//     настроек — общим `JobSubmission.applyingPowerRule` (`JobSubmissionPowerRule.swift`),
//     тем же, что у цепочки `SessionMachine.submitChain`.
//   • Инв. 32 (новый, IR-144): `retryJob` — задачи нет — `jobs.unknownJob` (тот же код, что
//     у `cancelJob`); повтор допустим только из `failed` и `cancelled`, из `pending`,
//     `running`, `succeeded` — `notAllowed(reason:)`. Подача собирается заново, а не
//     копируется: `JobSubmission.standard(прежняя нагрузка, runAfter: сейчас)` и правило
//     «только от сети» из ДЕЙСТВУЮЩИХ настроек; `dedupKey` — `nil`.
//   • «Что вне контракта»: `retryJob` не переиспользует прежний `jobId` — новая задача.
//   • Инв. 15: `retranscribe`/`cancelJob`/`retryJob` меняют очередь — публикуется
//     `statusChanged` до возврата; отказ событий не публикует.
//   • Инв. 19, §3.1: `JobQueueError` — `jobs.<имя case>`, `StorageError` — `storage.*`,
//     `permissionKind` — `nil`.
//
//  ЧТО КОНТРАКТ НЕ НАЗЫВАЕТ, И КАК ЭТО РЕШЕНО ЗДЕСЬ.
//   • Отказ чтения записи в `retranscribe` (`StorageError`) — `storage.*` по словарю, прочее —
//     `app.internalError`, как у прочих чтений фасада; задача не ставится.
//   • Текст `reason` у `notAllowed` — для человека, критериев на него нет (§3.1).
//   • `requireJobQueue` (фасад без очереди — `notAllowed`) — прежняя временная форма; по
//     уточнению инв. 31 (IR-144) снимается вместе с опциональностью `jobQueue` в MEE-462.

import Foundation

extension AppFacadeImpl {

    // MARK: - Чтение

    public func jobs(status: JobStatus) async throws -> [Job] {
        let queue = try requireJobQueue()
        do {
            return try await queue.jobs(status: status)
        } catch {
            throw wrapQueueFailure(error)
        }
    }

    // MARK: - Команды обработки (группа Н)

    public func retranscribe(recordingId: UUID, profileId: String) async throws -> UUID {
        let queue = try requireJobQueue()
        try await requireFinalizedRecording(recordingId)
        let missing: [ModelDescriptor]
        do {
            missing = try await modelCatalog.missingModels(profileId: profileId)
        } catch {
            throw wrapCatalogFailure(error)
        }
        guard missing.isEmpty else {
            throw AppFacadeError.profileNotReady(profileId: profileId, missingModelIds: missing.map(\.id))
        }
        let currentSettings = try await settings()
        let payload = JobPayload.transcribe(recordingId: recordingId, profileId: profileId, language: nil)
        let submission = JobSubmission.standard(payload, runAfter: clock()).applyingPowerRule(currentSettings)
        let jobId = try await submit(submission, to: queue)
        publish(.statusChanged(await status()))
        return jobId
    }

    public func cancelJob(id: UUID) async throws {
        let queue = try requireJobQueue()
        do {
            try await queue.cancel(jobId: id)
        } catch {
            throw wrapQueueFailure(error)
        }
        publish(.statusChanged(await status()))
    }

    public func retryJob(id: UUID) async throws -> UUID {
        let queue = try requireJobQueue()
        let previous: Job?
        do {
            previous = try await queue.job(id: id)
        } catch {
            throw wrapQueueFailure(error)
        }
        guard let previous else {
            throw wrap(JobQueueError.unknownJob(id))
        }
        guard Self.retryableStatuses.contains(previous.status) else {
            throw AppFacadeError.notAllowed(reason: "retryJob: повтор допустим только из failed и cancelled, "
                + "задача \(id) — \(previous.status.rawValue)")
        }
        let currentSettings = try await settings()
        let submission = JobSubmission.standard(previous.payload, runAfter: clock()).applyingPowerRule(currentSettings)
        let jobId = try await submit(submission, to: queue)
        publish(.statusChanged(await status()))
        return jobId
    }

    // MARK: - Вспомогательное

    /// Инв. 32: статусы C-013, из которых повтор допустим.
    private static let retryableStatuses: Set<JobStatus> = [.failed, .cancelled]

    /// Инв. 12 (IR-144): запись есть и `.finalized`, иначе `notFound` / `notAllowed`.
    private func requireFinalizedRecording(_ recordingId: UUID) async throws {
        let record: RecordingRecord?
        do {
            record = try await recordings.recording(id: recordingId)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        guard let record else {
            throw AppFacadeError.notFound(entity: "Recording", id: recordingId.uuidString)
        }
        guard record.status == .finalized else {
            throw AppFacadeError.notAllowed(
                reason: "retranscribe: запись \(recordingId) не завершена (\(record.status.rawValue))"
            )
        }
    }

    private func requireJobQueue() throws -> JobQueue {
        guard let jobQueue else {
            throw AppFacadeError.notAllowed(reason: "AppFacadeImpl: очередь задач (JobQueue) фасаду не передана")
        }
        return jobQueue
    }

    private func submit(_ submission: JobSubmission, to queue: JobQueue) async throws -> UUID {
        do {
            return try await queue.submit(submission)
        } catch {
            throw wrapQueueFailure(error)
        }
    }

    // MARK: - `jobs.*` (§3.1, строка `JobQueueError`)

    /// Отказ очереди: `JobQueueError` — по словарю, `StorageError` хранилища очереди —
    /// `storage.*`, прочее — `app.internalError`.
    func wrapQueueFailure(_ error: Error) -> AppFacadeError {
        switch error {
        case let queueError as JobQueueError: return wrap(queueError)
        case let storageError as StorageError: return wrap(storageError)
        default: return wrapUnexpected(error)
        }
    }

    /// `jobs.<имя case>` правилом §3.1 (`ruleView`); `permissionKind` — `nil`.
    func wrap(_ error: JobQueueError) -> AppFacadeError {
        .underlying(Self.ruleView(prefix: "jobs", error: error))
    }
}
