//  MeetingsWindowModel — чистая логика окна «Встречи» (MEE-474): неделя, список, выбор встречи,
//  записи и транскрипта, реакция на `AppEvent`. Без SwiftUI и без `AppFacade`-вызовов — только
//  значения (тот же приём, что `MenuBarModel.swift`: тестового таргета у App нет, логику
//  проверяют чтением).
//
//  Как устроено. Каждый вход (`select…`, `apply(event:)`, `finish…`) меняет состояние и
//  возвращает список чтений `MeetingsLoad`, которые контроллер (`MeetingsController.swift`)
//  исполняет против фасада и отдаёт обратно в `finish…`. У каждого вида чтения свой счётчик
//  поколения: ответ на устаревший запрос (неделю уже переключили, встречу уже сменили)
//  отбрасывается, а не перетирает свежий.
//
//  Окно не держит копий дольше своей жизни: состояние живёт в контроллере, контроллер — пока
//  открыто окно (`MeetingsWindowPresenter`). Источник истины — фасад и его события.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

// MARK: - Неделя

struct MeetingsWeek: Equatable, Sendable {
    let start: Date
    let end: Date

    /// Григорианский календарь с понедельником первым днём, в поясе пользователя.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "ru_RU")
        calendar.firstWeekday = 2
        calendar.timeZone = .current
        return calendar
    }

    static func containing(_ date: Date, calendar: Calendar = MeetingsWeek.calendar) -> MeetingsWeek {
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: date) else {
            let start = calendar.startOfDay(for: date)
            return MeetingsWeek(start: start, end: start.addingTimeInterval(7 * 24 * 3600))
        }
        return MeetingsWeek(start: interval.start, end: interval.end)
    }

    func shifted(by weeks: Int, calendar: Calendar = MeetingsWeek.calendar) -> MeetingsWeek {
        let moved = calendar.date(byAdding: .weekOfYear, value: weeks, to: start) ?? start
        return MeetingsWeek.containing(moved, calendar: calendar)
    }
}

// MARK: - Чтения, которые модель просит у фасада

enum MeetingsLoad: Equatable, Sendable {
    /// `meetings(from:to:)`.
    case list(week: MeetingsWeek, generation: Int)
    /// `meeting(id:)`.
    case detail(meetingId: UUID, generation: Int)
    /// `latestTranscript(recordingId:)` при `.latest`, иначе `transcript(id:)`.
    case transcript(recordingId: UUID, selection: TranscriptSelection, generation: Int)
    /// `jobs(status:)` для `.running`, `.pending`, `.failed` и `status()`.
    case processing(generation: Int)
}

enum TranscriptSelection: Hashable, Sendable {
    /// Последняя версия — `latestTranscript(recordingId:)`; новая версия подхватывается сама.
    case latest
    /// Выбранная пользователем версия по `TranscriptHeader.id` — `transcript(id:)`.
    case version(UUID)
}

// MARK: - Содержимое областей окна

enum MeetingsListContent: Equatable, Sendable {
    case loading
    case loaded([MeetingListItem])
    /// Чтение бросило (`AppFacadeError`): ошибка на месте списка, окно не падает.
    case failed(AppErrorView)
}

enum MeetingDetailContent: Equatable, Sendable {
    case none
    case loading
    case loaded(MeetingDetail)
    case notFound
    case failed(AppErrorView)
}

enum TranscriptContent: Equatable, Sendable {
    case none
    case loading
    case loaded(TranscriptView)
    /// Фасад ответил `nil`: транскрипта (или выбранной версии) нет.
    case missing
    case failed(AppErrorView)
}

/// Снимок очереди для блока «Состояние обработки». `jobs(status:)` — по записи через
/// `JobPayload`, `status().runningJobs` — доля и этап.
struct ProcessingSnapshot: Equatable, Sendable {
    var running: [Job] = []
    var pending: [Job] = []
    var failed: [Job] = []
}

// MARK: - Состояние

struct MeetingsWindowState: Equatable, Sendable {

    private(set) var week: MeetingsWeek
    private(set) var list: MeetingsListContent = .loading
    private(set) var selectedMeetingId: UUID?
    private(set) var detail: MeetingDetailContent = .none
    private(set) var selectedRecordingId: UUID?
    private(set) var transcriptSelection: TranscriptSelection = .latest
    private(set) var transcript: TranscriptContent = .none

    /// Последний снимок `status()`/`statusChanged` — для `runningJobs`.
    private(set) var status: AppStatus?
    /// Доли по `AppEvent.jobProgressed`, ключ — `jobId`.
    private(set) var jobFractions: [UUID: Double] = [:]
    private(set) var processing = ProcessingSnapshot()
    private(set) var processingError: AppErrorView?
    /// Отказавшие задачи, которые это окно уже повторило: прежняя строка `failed` в очереди
    /// остаётся (`retryJob` ставит новую задачу, C-016 «Что вне контракта»), кнопку к ней
    /// второй раз не показываем.
    private(set) var retriedJobIds: Set<UUID> = []
    /// Задача, повтор которой ещё не ответил. Пока она есть, «Повторить» неактивна.
    private(set) var retryInFlight: UUID?
    /// Отказ команды окна (`retryJob`) — одна строка в карточке.
    private(set) var actionError: AppErrorView?

    private(set) var listGeneration = 0
    private(set) var detailGeneration = 0
    private(set) var transcriptGeneration = 0
    private(set) var processingGeneration = 0

    init(now: Date) {
        week = MeetingsWeek.containing(now)
    }

    // MARK: Входы пользователя

    /// Первые чтения при открытии окна.
    mutating func start() -> [MeetingsLoad] {
        [reloadList(), reloadProcessing()]
    }

    mutating func show(week newWeek: MeetingsWeek) -> [MeetingsLoad] {
        week = newWeek
        list = .loading
        return [reloadList()]
    }

    /// Выбор строки списка. `nil` — снять выбор.
    mutating func select(meetingId: UUID?) -> [MeetingsLoad] {
        guard meetingId != selectedMeetingId else { return [] }
        selectedMeetingId = meetingId
        selectedRecordingId = nil
        transcriptSelection = .latest
        transcript = .none
        transcriptGeneration += 1
        actionError = nil
        guard meetingId != nil else {
            detail = .none
            detailGeneration += 1
            return []
        }
        detail = .loading
        return reloadDetail()
    }

    mutating func select(recordingId: UUID) -> [MeetingsLoad] {
        guard recordingId != selectedRecordingId else { return [] }
        selectedRecordingId = recordingId
        transcriptSelection = .latest
        return reloadTranscript(resetting: true)
    }

    mutating func select(transcript selection: TranscriptSelection) -> [MeetingsLoad] {
        guard selection != transcriptSelection else { return [] }
        transcriptSelection = selection
        return reloadTranscript(resetting: true)
    }

    /// Повтор чтения после отказа (кнопка «Повторить загрузку»).
    mutating func retryReads() -> [MeetingsLoad] {
        list = .loading
        var loads = [reloadList(), reloadProcessing()]
        if selectedMeetingId != nil {
            detail = .loading
            loads += reloadDetail()
        }
        return loads
    }

    // MARK: Генерации

    mutating func reloadList() -> MeetingsLoad {
        listGeneration += 1
        return .list(week: week, generation: listGeneration)
    }

    mutating func reloadDetail() -> [MeetingsLoad] {
        guard let meetingId = selectedMeetingId else { return [] }
        detailGeneration += 1
        return [.detail(meetingId: meetingId, generation: detailGeneration)]
    }

    mutating func reloadProcessing() -> MeetingsLoad {
        processingGeneration += 1
        return .processing(generation: processingGeneration)
    }

    /// `resetting` — смена записи или версии: старый текст не показываем до ответа. Без него
    /// (событие) старый текст остаётся на месте, пока не придёт новый.
    mutating func reloadTranscript(resetting: Bool) -> [MeetingsLoad] {
        transcriptGeneration += 1
        guard let recordingId = selectedRecordingId, recordingHasTranscripts(recordingId) else {
            transcript = .none
            return []
        }
        if resetting { transcript = .loading }
        return [.transcript(recordingId: recordingId, selection: transcriptSelection, generation: transcriptGeneration)]
    }

    func recordingHasTranscripts(_ recordingId: UUID) -> Bool {
        guard case .loaded(let detail) = detail else { return false }
        return detail.recordings.first { $0.recordingId == recordingId }?.transcripts.isEmpty == false
    }

    // MARK: Ответы фасада

    mutating func finishList(generation: Int, _ content: MeetingsListContent) {
        guard generation == listGeneration else { return }
        list = content
    }

    mutating func finishDetail(generation: Int, _ content: MeetingDetailContent) -> [MeetingsLoad] {
        guard generation == detailGeneration else { return [] }
        detail = content
        guard case .loaded(let loaded) = content else {
            selectedRecordingId = nil
            transcript = .none
            transcriptGeneration += 1
            return []
        }
        // Выбранная запись пропала (удалена) или ещё не выбрана — берём последнюю по времени.
        if let selected = selectedRecordingId, loaded.recordings.contains(where: { $0.recordingId == selected }) {
            return reloadTranscript(resetting: false)
        }
        selectedRecordingId = loaded.recordings.max { $0.startedAt < $1.startedAt }?.recordingId
        transcriptSelection = .latest
        return reloadTranscript(resetting: true)
    }

    mutating func finishTranscript(generation: Int, _ content: TranscriptContent) {
        guard generation == transcriptGeneration else { return }
        transcript = content
    }

    mutating func finishProcessing(generation: Int, status newStatus: AppStatus, jobs: ProcessingSnapshot?,
                                   error: AppErrorView?) {
        apply(status: newStatus)
        guard generation == processingGeneration else { return }
        if let jobs { processing = jobs }
        processingError = error
    }
}

// MARK: - События фасада и «Повторить»

/// Разведено из тела типа по объёму (`type_body_length`); в том же файле — ради `private(set)`.
extension MeetingsWindowState {

    mutating func apply(event: AppEvent) -> [MeetingsLoad] {
        switch event {
        case .meetingsChanged:
            // Список недели и карточка (признаки, записи, заголовки транскриптов).
            return [reloadList()] + reloadDetail()
        case .transcriptChanged(let transcriptId):
            return applyTranscriptChanged(transcriptId)
        case .statusChanged(let newStatus):
            return applyStatusChanged(newStatus)
        case .jobProgressed(let jobId, _, let fraction):
            jobFractions[jobId] = min(max(fraction, 0), 1)
            return []
        case .failure:
            // Асинхронный отказ задачи (инв. 31): строку «Повторить» даёт `jobs(status: .failed)`.
            return [reloadProcessing()]
        case .permissionsChanged, .modelsChanged, .settingsChanged:
            return []
        }
    }

    /// Новая или изменённая версия транскрипта. Какой записи она принадлежит, событие не
    /// говорит — перечитываем карточку (заголовки версий); `finishDetail` сам перечитает
    /// показанный текст. Показанная выбранная версия перечитывается сразу.
    private mutating func applyTranscriptChanged(_ transcriptId: UUID) -> [MeetingsLoad] {
        var loads = reloadDetail()
        if loads.isEmpty, case .loaded(let shown) = transcript, shown.header.id == transcriptId {
            loads += reloadTranscript(resetting: false)
        }
        return loads
    }

    /// Очередь в снимке поменялась — перечитать задачи для блока «Состояние обработки».
    private mutating func applyStatusChanged(_ newStatus: AppStatus) -> [MeetingsLoad] {
        let previous = status
        apply(status: newStatus)
        guard status == newStatus else { return [] }
        let queueChanged = previous.map {
            $0.runningJobs.map(\.jobId) != newStatus.runningJobs.map(\.jobId)
                || $0.pendingJobCount != newStatus.pendingJobCount
                || $0.failedJobCount != newStatus.failedJobCount
        } ?? true
        return queueChanged ? [reloadProcessing()] : []
    }

    /// Снимок старше текущего по `updatedAt` отбрасывается — тот же приём, что у меню-бара
    /// (MEE-478 п. 1).
    mutating func apply(status newStatus: AppStatus) {
        if let current = status, newStatus.updatedAt < current.updatedAt { return }
        status = newStatus
        let running = Set(newStatus.runningJobs.map(\.jobId))
        jobFractions = jobFractions.filter { running.contains($0.key) }
    }

    // MARK: «Повторить»

    /// `false` — повтор уже идёт, второе нажатие не шлёт второй `retryJob`.
    mutating func beginRetry(jobId: UUID) -> Bool {
        guard retryInFlight == nil else { return false }
        retryInFlight = jobId
        actionError = nil
        return true
    }

    /// `error == nil` — фасад поставил новую задачу.
    mutating func finishRetry(jobId: UUID, error: AppErrorView?) -> [MeetingsLoad] {
        guard retryInFlight == jobId else { return [] }
        retryInFlight = nil
        if let error {
            actionError = error
        } else {
            retriedJobIds.insert(jobId)
        }
        return [reloadProcessing()]
    }

    mutating func dismissActionError() {
        actionError = nil
    }
}
