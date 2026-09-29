//  AppFacadeImpl — очередь в `status()` и события очереди: `jobProgressed`, `statusChanged`
//  (C-016 v13, инв. 35; IR-147, MEE-476; задача MEE-477).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ИСТОЧНИК ОДИН — `JobQueue` (инв. 31, обязательная зависимость): `jobs(status:)` для
//  состава, `job(id:)` для типа задачи без пары, `events()` для долей и поводов публикации.
//  Своего у фасада — только последняя наблюдённая доля идущей задачи и последняя
//  опубликованная доля (правило приращения (д)), плюс пара `jobId → type` с `started`.
//
//  ТОЛКОВАНИЕ, КОТОРОГО КОНТРАКТ ДОСЛОВНО НЕ НАЗЫВАЕТ (вынесено в отчёт MEE-477):
//   • `started` открывает новую попытку: наблюдённая и опубликованная доли задачи
//     сбрасываются. Иначе после `failed(willRetry: true)` и повторного `started` в
//     `runningJobs` висела бы доля прошлой попытки, а правило приращения молчало бы, пока
//     новая попытка не догонит старую.
//   • Приращение «не меньше 0.01» сравнивается с допуском `1e-9`: в `Double`
//     `0.11 - 0.10 < 0.01`, и вектор (35д) иначе потерял бы 0.11.
//   • `meetingId` у `attribute(meetingId: nil)` — из манифеста записи: `nil` в нагрузке
//     считается «не несёт».

import Foundation

/// Наблюдённое по `JobQueue.events()` — ровно то, что нужно инв. 35 (а) и (д).
struct JobObservation: Sendable {
    /// Пара `jobId → type` с `started` (или с `job(id:)`, если `started` не было).
    var types: [UUID: JobType] = [:]
    /// Доля последнего `progressed`, приведённая к `0...1` — `RunningJobView.fraction`.
    var observedFraction: [UUID: Double] = [:]
    /// Последняя опубликованная в `jobProgressed` доля — база правила приращения (д).
    var publishedFraction: [UUID: Double] = [:]

    mutating func forget(_ jobId: UUID) {
        types[jobId] = nil
        observedFraction[jobId] = nil
        publishedFraction[jobId] = nil
    }

    mutating func startAttempt(_ jobId: UUID, type: JobType) {
        types[jobId] = type
        observedFraction[jobId] = nil
        publishedFraction[jobId] = nil
    }
}

/// Сводка очереди для `AppStatus` — инв. 35 (а)–(г).
struct JobQueueSummary: Sendable {
    var runningJobs: [RunningJobView] = []
    var pendingJobCount = 0
    var failedJobCount = 0

    static let unknown = JobQueueSummary()
}

extension AppFacadeImpl {

    /// Минимальное приращение опубликованной доли (инв. 35 (д)).
    static let progressPublishStep = 0.01
    /// Допуск сравнения приращения: `Double` не держит сотые точно.
    static let progressPublishTolerance = 1e-9

    // MARK: - Инв. 35 (д), (е): события очереди

    /// Одно событие очереди. `failure` по инв. 31 публикует `handleJobEvent` до этого вызова.
    func observeJobEvent(_ event: JobEvent) async {
        switch event {
        case .submitted:
            publish(.statusChanged(await status()))
        case let .started(jobId, type):
            jobObservation.startAttempt(jobId, type: type)
            publish(.statusChanged(await status()))
        case let .progressed(jobId, fraction):
            await observeProgress(jobId: jobId, fraction: fraction)
        case let .succeeded(jobId, _), let .cancelled(jobId, _):
            jobObservation.forget(jobId)
            publish(.statusChanged(await status()))
        case let .failed(jobId, _, _, willRetry):
            if !willRetry {
                jobObservation.forget(jobId)
            }
            publish(.statusChanged(await status()))
        case .blocked:
            return
        }
    }

    /// (д): `type` — из пары `started`; пары нет — `job(id:)`; задачи нет — не публикуется.
    /// Не число — отбрасывается; прочее приводится к `0...1`. Первое по задаче — всегда,
    /// дальше — при приращении не меньше `0.01` к последней опубликованной доле.
    private func observeProgress(jobId: UUID, fraction raw: Double) async {
        guard !raw.isNaN else { return }
        let fraction = min(max(raw, 0), 1)
        let type: JobType
        if let known = jobObservation.types[jobId] {
            type = known
        } else if let job = try? await jobQueue.job(id: jobId) {
            type = job.type
            jobObservation.types[jobId] = type
        } else {
            return
        }
        jobObservation.observedFraction[jobId] = fraction
        if let published = jobObservation.publishedFraction[jobId],
           fraction - published < Self.progressPublishStep - Self.progressPublishTolerance {
            return
        }
        jobObservation.publishedFraction[jobId] = fraction
        publish(.jobProgressed(jobId: jobId, type: type, fraction: fraction))
    }

    // MARK: - Инв. 35 (а)–(г): сводка очереди для `status()`

    /// (г): любое чтение состава бросило — пустой `runningJobs` и нули.
    func jobQueueSummary() async -> JobQueueSummary {
        do {
            let running = try await jobQueue.jobs(status: .running)
            let pending = try await jobQueue.jobs(status: .pending)
            let failed = try await jobQueue.jobs(status: .failed)
            let succeeded = try await jobQueue.jobs(status: .succeeded)
            var views: [RunningJobView] = []
            for job in running.sorted(by: Self.queueOrder) {
                views.append(await runningJobView(job))
            }
            return JobQueueSummary(
                runningJobs: views,
                pendingJobCount: pending.count,
                failedJobCount: Self.unrepairedFailures(failed: failed, later: running + pending + succeeded)
            )
        } catch {
            return .unknown
        }
    }

    /// (а): порядок — `createdAt`, затем `id.uuidString`.
    static func queueOrder(_ lhs: Job, _ rhs: Job) -> Bool {
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// (в): `failed`-задачи, у которых нет более поздней (по `createdAt`) задачи с равной
    /// `payload` в `pending`, `running` или `succeeded`.
    static func unrepairedFailures(failed: [Job], later candidates: [Job]) -> Int {
        failed.filter { failure in
            !candidates.contains { $0.payload == failure.payload && $0.createdAt > failure.createdAt }
        }.count
    }

    /// (а): `jobId`, `type` — из `Job`; `recordingId`, `meetingId` — из нагрузки, иначе из
    /// заголовка транскрипта и манифеста записи; `fraction` — последняя наблюдённая доля,
    /// `0` до первого `progressed`; `stage` — всегда `nil`. Отказ дочитки даёт `nil`, а не
    /// отказ всей сводки: поля необязательны, а (г) говорит о чтении очереди.
    private func runningJobView(_ job: Job) async -> RunningJobView {
        var recordingId: UUID?
        var meetingId: UUID?
        switch job.payload {
        case let .transcode(id), let .transcribe(id, _, _), let .diarize(id, _):
            recordingId = id
        case let .attribute(transcriptId, payloadMeetingId):
            recordingId = (try? await transcripts.transcript(id: transcriptId))?.recordingId
            meetingId = payloadMeetingId
        case let .summarize(payloadMeetingId, _, _):
            meetingId = payloadMeetingId
        }
        if meetingId == nil, let recordingId {
            meetingId = (try? await recordings.recording(id: recordingId))?.manifest.meetingId
        }
        return RunningJobView(
            jobId: job.id, type: job.type, meetingId: meetingId, recordingId: recordingId,
            fraction: jobObservation.observedFraction[job.id] ?? 0, stage: nil
        )
    }
}
