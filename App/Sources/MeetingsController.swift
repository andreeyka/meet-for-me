//  MeetingsController — исполняет чтения `MeetingsLoad` и команду «Повторить» против
//  `AppFacade` и держит `MeetingsWindowState` на время жизни окна «Встречи» (MEE-474). Логики
//  «что показать» не держит — она в `MeetingsWindowModel.swift` и `*Presentation.swift`; здесь
//  только `await` и подписка на `events()`.
//
//  Время жизни — окно, не вид: контроллер создаёт `MeetingsWindowPresenter` при открытии окна
//  и останавливает при закрытии. `.task` вида не используется (тот же приём, что у меню-бара):
//  подписка и данные не переживают окно, но и не зависят от пересборки вида.
//
//  П7: только `AppFacade`.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

@MainActor
final class MeetingsController: ObservableObject {

    @Published private(set) var state: MeetingsWindowState

    private let facade: AppFacade
    private var eventsTask: Task<Void, Never>?

    init(facade: AppFacade, now: Date = Date()) {
        self.facade = facade
        self.state = MeetingsWindowState(now: now)
    }

    // MARK: Жизненный цикл

    func start() {
        guard eventsTask == nil else { return }
        let stream = facade.events()
        eventsTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.run(self.state.apply(event: event))
            }
        }
        run(state.start())
    }

    func stop() {
        eventsTask?.cancel()
        eventsTask = nil
    }

    // MARK: Входы вида

    func showPreviousWeek() { run(state.show(week: state.week.shifted(by: -1))) }
    func showNextWeek() { run(state.show(week: state.week.shifted(by: 1))) }
    func showCurrentWeek() { run(state.show(week: MeetingsWeek.containing(Date()))) }
    func select(row: MeetingRow.Kind?) { run(state.select(row: row)) }
    func select(recordingId: UUID) { run(state.select(recordingId: recordingId)) }
    func select(transcript selection: TranscriptSelection) { run(state.select(transcript: selection)) }
    func retryReads() { run(state.retryReads()) }
    func retryTranscript() { run(state.retryTranscript()) }
    func dismissActionError() { state.dismissActionError() }

    /// «Повторить» у отказавшей задачи. Пока предыдущий повтор не ответил, нажатие ничего не шлёт.
    func retry(jobId: UUID) {
        guard state.beginRetry(jobId: jobId) else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.facade.retryJob(id: jobId)
                self.run(self.state.finishRetry(jobId: jobId, succeeded: true, error: nil))
            } catch {
                let shown = FacadeErrorText.shownError(error)
                self.run(self.state.finishRetry(jobId: jobId, succeeded: false, error: shown))
            }
        }
    }

    // MARK: Исполнение чтений

    private func run(_ loads: [MeetingsLoad]) {
        for load in loads {
            // Отмены нет — чтение короткое (локальная база). `self?` разворачивается до вызова,
            // поэтому задача держит контроллер сильно, пока идёт `execute`: закрытое окно
            // дожидается ответа, ответ пишется в состояние, которое уже никто не показывает, и
            // контроллер освобождается вместе с последней такой задачей (MEE-487 п. 11).
            Task { [weak self] in await self?.execute(load) }
        }
    }

    private func execute(_ load: MeetingsLoad) async {
        switch load {
        case .list(let week, let generation):
            let content = await read(failed: MeetingsListContent.failed) {
                .loaded(try await facade.meetings(from: week.start, to: week.end))
            }
            if let content { state.finishList(generation: generation, content) }
        case .adHocList(let week, let generation):
            let content = await read(failed: AdHocListContent.failed) {
                .loaded(try await facade.adHocRecordings(from: week.start, to: week.end))
            }
            if let content { run(state.finishAdHoc(generation: generation, content)) }
        case .detail(let meetingId, let generation):
            let content = await read(failed: MeetingDetailContent.failed) {
                try await facade.meeting(id: meetingId).map(MeetingDetailContent.loaded) ?? .notFound
            }
            if let content { run(state.finishDetail(generation: generation, content)) }
        case .transcript(let recordingId, let selection, let generation):
            let content = await read(failed: TranscriptContent.failed) {
                try await transcript(recordingId: recordingId, selection).map(TranscriptContent.loaded) ?? .missing
            }
            if let content { state.finishTranscript(generation: generation, content) }
        case .processing(let generation):
            await executeProcessing(generation: generation)
        }
    }

    /// Одно чтение фасада → содержимое области. Отказ `AppFacadeError` — `failed(view)`; бросок
    /// другого типа (`CancellationError`) не переводится и не показывается (C-016 v13 инв. 37):
    /// `nil`, ответ отбрасывается, как устаревший.
    private func read<Content>(
        failed: (AppErrorView) -> Content, _ body: () async throws -> Content
    ) async -> Content? {
        do {
            return try await body()
        } catch {
            return FacadeErrorText.shownError(error).map(failed)
        }
    }

    private func transcript(recordingId: UUID, _ selection: TranscriptSelection) async throws -> TranscriptView? {
        switch selection {
        case .latest: return try await facade.latestTranscript(recordingId: recordingId)
        case .version(let id): return try await facade.transcript(id: id)
        }
    }

    /// Идущие задачи — из `status().runningJobs` (C-016 v13 инв. 35 (а)); запасного чтения
    /// `jobs(status: .running)` больше нет (MEE-487 п. 2).
    private func executeProcessing(generation: Int) async {
        let status = await facade.status()
        do {
            let snapshot = ProcessingSnapshot(
                pending: try await facade.jobs(status: .pending),
                failed: try await facade.jobs(status: .failed)
            )
            state.finishProcessing(generation: generation, status: status, jobs: snapshot, error: nil)
        } catch {
            state.finishProcessing(
                generation: generation, status: status, jobs: nil, error: FacadeErrorText.shownError(error)
            )
        }
    }
}
