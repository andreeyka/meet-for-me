//  ProcessingPresentation — блок «Состояние обработки» записи без транскрипта (MEE-474 п. 4).
//  Чистая функция от `MeetingsWindowState`, без SwiftUI.
//
//  Порядок источников:
//   1. `status().runningJobs` по `recordingId` — доля (накрытая `AppEvent.jobProgressed`) и этап
//      (C-016 v13 инв. 35 (а); запасного `jobs(status: .running)` больше нет — MEE-487 п. 2);
//   2. `jobs(status: .pending)` — задача в очереди;
//   3. `jobs(status: .failed)` — последняя по `updatedAt` отказавшая задача записи, кнопка
//      «Повторить» → `retryJob(id:)`. Уже повторённая этим окном — не показывается;
//   4. иначе — по статусу записи.
//
//  Задачи `attribute`/`summarize` записи не называют (`JobPayload` несёт `transcriptId`/
//  `meetingId`) и идут после транскрипта — блоку, который виден только без транскрипта, они
//  не нужны.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

struct ProcessingLine: Equatable, Sendable {
    let text: String
    /// Отказавшая задача, которую можно повторить. `nil` — кнопки нет.
    let retryJobId: UUID?
    let isRetryEnabled: Bool
    let isFailure: Bool

    static func info(_ text: String) -> ProcessingLine {
        ProcessingLine(text: text, retryJobId: nil, isRetryEnabled: false, isFailure: false)
    }

    static func make(recording: RecordingSummary, state: MeetingsWindowState) -> ProcessingLine {
        let recordingId = recording.recordingId
        if let view = state.status?.runningJobs.first(where: { $0.recordingId == recordingId }) {
            let fraction = state.jobFractions[view.jobId] ?? view.fraction
            let stage = view.stage.map { " (\($0))" } ?? ""
            return info("\(FacadeErrorText.jobTitle(view.type))\(stage): \(Int((fraction * 100).rounded()))%")
        }
        let jobs = state.processing
        if let job = Self.latest(jobs.pending, recordingId: recordingId) {
            return info("\(FacadeErrorText.jobTitle(job.type)): в очереди")
        }
        let failed = jobs.failed.filter { !state.retriedJobIds.contains($0.id) }
        if let job = Self.latest(failed, recordingId: recordingId) {
            let reason = job.lastError.map { ": \($0)" } ?? ""
            return ProcessingLine(
                text: "Отказ: \(FacadeErrorText.jobTitle(job.type))\(reason)",
                retryJobId: job.id,
                isRetryEnabled: state.retryInFlight == nil,
                isFailure: true
            )
        }
        return info(idleText(recording.status))
    }

    static func idleText(_ status: RecordingStatus) -> String {
        switch status {
        case .recording, .stopping: return "Идёт запись — транскрипт появится после обработки"
        case .finalized: return "Транскрипта пока нет"
        case .failed: return "Запись не удалась — транскрипта не будет"
        }
    }

    static func latest(_ jobs: [Job], recordingId: UUID) -> Job? {
        jobs.filter { Self.recordingId(of: $0.payload) == recordingId }
            .max { $0.updatedAt < $1.updatedAt }
    }

    static func recordingId(of payload: JobPayload) -> UUID? {
        switch payload {
        case .transcode(let recordingId),
             .transcribe(let recordingId, _, _),
             .diarize(let recordingId, _):
            return recordingId
        case .attribute, .summarize:
            return nil
        }
    }
}
