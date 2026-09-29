//  AppFacadeImpl — команды обработки и чтение задач, группа Н плана MEE-410 (C-016 v10,
//  MEE-25; К37, К38, строки `jobs.*` К27 перечня MEE-401; задача MEE-420).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧТО НАЗВАНО КОНТРАКТОМ.
//   • Инв. 12: `retranscribe` с профилем, которому не хватает моделей, бросает
//     `profileNotReady(profileId:missingModelIds:)` и задачу не ставит. Недостающие модели
//     называет каталог (`ModelCatalogPort.missingModels(profileId:)`, C-014 инв. 10).
//   • «Что вне контракта»: `retryJob` не переиспользует прежний `jobId` — новая задача.
//   • §«Поведение»: какую задачу ставить, решает не фасад. Подача `retranscribe` —
//     `JobSubmission.standard(_:runAfter:)` (таблица §4 C-013) с правилом §4 C-013
//     «только от сети» из действующих настроек — тем же путём, что цепочка
//     `SessionMachine.submitChain`; `language` — `nil`, как у цепочки.
//   • Инв. 19, §3.1: `JobQueueError` — `jobs.<имя case>`, `permissionKind` — `nil`.
//
//  ЧТО КОНТРАКТ НЕ НАЗЫВАЕТ, И КАК ЭТО РЕШЕНО ЗДЕСЬ (вопросы — в отчёте MEE-420).
//   • Очередь фасаду до этой задачи не передавалась. `AppFacadeImpl.init` получил параметр
//     `jobQueue: JobQueue? = nil` — по умолчанию `nil`, чтобы не ломать композиционный
//     корень `App/` (зона DEV-1). Без очереди команды группы Н отказывают `notAllowed`.
//   • `retryJob` несуществующей задачи — `jobs.unknownJob`, тот же код, что отдаёт
//     `cancelJob` от очереди (`JobQueueEngine.cancel`). Статус прежней задачи не
//     проверяется: контракт не говорит, какие статусы допускают повтор. Подача повторяет
//     прежнюю (нагрузка, приоритет, попытки, условия, `dedupKey`), `runAfter` — сейчас.
//   • События: `retranscribe`/`cancelJob`/`retryJob` меняют очередь — публикуется
//     `statusChanged` (инв. 15; `AppStatus` несёт состояние очереди).

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
        let submission = Self.applyingPowerRule(
            JobSubmission.standard(payload, runAfter: clock()), settings: currentSettings
        )
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
        let submission = JobSubmission(
            payload: previous.payload, priority: previous.priority, maxAttempts: previous.maxAttempts,
            runAfter: clock(), conditions: previous.conditions, dedupKey: nil
        )
        let jobId = try await submit(submission, to: queue)
        publish(.statusChanged(await status()))
        return jobId
    }

    // MARK: - Вспомогательное

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

    /// Правило §4 C-013: «обрабатывать только от сети» поднимает `requiresACPower` при
    /// постановке — тот же ход, что `SessionMachine.submitChain`.
    static func applyingPowerRule(_ submission: JobSubmission, settings: AppSettings) -> JobSubmission {
        guard settings.processOnACPowerOnly, !submission.conditions.requiresACPower else { return submission }
        return JobSubmission(
            payload: submission.payload, priority: submission.priority, maxAttempts: submission.maxAttempts,
            runAfter: submission.runAfter,
            conditions: JobConditions(
                requiresACPower: true,
                forbidWhileRecording: submission.conditions.forbidWhileRecording,
                maxThermalPressure: submission.conditions.maxThermalPressure,
                requiresProfileReady: submission.conditions.requiresProfileReady
            ),
            dedupKey: submission.dedupKey
        )
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
