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
    func select(meetingId: UUID?) { run(state.select(meetingId: meetingId)) }
    func select(recordingId: UUID) { run(state.select(recordingId: recordingId)) }
    func select(transcript selection: TranscriptSelection) { run(state.select(transcript: selection)) }
    func retryReads() { run(state.retryReads()) }
    func dismissActionError() { state.dismissActionError() }

    /// «Повторить» у отказавшей задачи. Пока предыдущий повтор не ответил, нажатие ничего не шлёт.
    func retry(jobId: UUID) {
        guard state.beginRetry(jobId: jobId) else { return }
        Task { [weak self] in
            guard let self else { return }
            var failure: AppErrorView?
            do {
                _ = try await self.facade.retryJob(id: jobId)
            } catch {
                failure = FacadeErrorText.view(for: error)
            }
            self.run(self.state.finishRetry(jobId: jobId, error: failure))
        }
    }

    // MARK: Исполнение чтений

    private func run(_ loads: [MeetingsLoad]) {
        for load in loads {
            // Чтение короткое и не отменяется: после закрытия окна его ответ уходит в
            // контроллер, который уже никто не держит, и пропадает вместе с ним.
            Task { [weak self] in await self?.execute(load) }
        }
    }

    private func execute(_ load: MeetingsLoad) async {
        switch load {
        case .list(let week, let generation):
            let content: MeetingsListContent
            do {
                content = .loaded(try await facade.meetings(from: week.start, to: week.end))
            } catch {
                content = .failed(FacadeErrorText.view(for: error))
            }
            state.finishList(generation: generation, content)
        case .detail(let meetingId, let generation):
            let content: MeetingDetailContent
            do {
                content = try await facade.meeting(id: meetingId).map(MeetingDetailContent.loaded) ?? .notFound
            } catch {
                content = .failed(FacadeErrorText.view(for: error))
            }
            run(state.finishDetail(generation: generation, content))
        case .transcript(let recordingId, let selection, let generation):
            state.finishTranscript(generation: generation, await transcript(recordingId: recordingId, selection))
        case .processing(let generation):
            await executeProcessing(generation: generation)
        }
    }

    private func transcript(recordingId: UUID, _ selection: TranscriptSelection) async -> TranscriptContent {
        do {
            let view: TranscriptView?
            switch selection {
            case .latest: view = try await facade.latestTranscript(recordingId: recordingId)
            case .version(let id): view = try await facade.transcript(id: id)
            }
            return view.map(TranscriptContent.loaded) ?? .missing
        } catch {
            return .failed(FacadeErrorText.view(for: error))
        }
    }

    private func executeProcessing(generation: Int) async {
        let status = await facade.status()
        do {
            let snapshot = ProcessingSnapshot(
                running: try await facade.jobs(status: .running),
                pending: try await facade.jobs(status: .pending),
                failed: try await facade.jobs(status: .failed)
            )
            state.finishProcessing(generation: generation, status: status, jobs: snapshot, error: nil)
        } catch {
            state.finishProcessing(
                generation: generation, status: status, jobs: nil, error: FacadeErrorText.view(for: error)
            )
        }
    }
}
