//  MeetingsWindowModel — чистая логика окна «Встречи» (MEE-474): неделя, список, выбор строки,
//  записи и транскрипта, реакция на `AppEvent`. Без SwiftUI и без `AppFacade`-вызовов — только
//  значения (тот же приём, что `MenuBarModel.swift`: тестового таргета у App нет, логику
//  проверяют чтением). Типы значений — `MeetingsWindowTypes.swift`.
//
//  Как устроено. Каждый вход (`select…`, `apply(event:)`, `finish…`) меняет состояние и
//  возвращает список чтений `MeetingsLoad`, которые контроллер (`MeetingsController.swift`)
//  исполняет против фасада и отдаёт обратно в `finish…`. У каждого вида чтения свой счётчик
//  поколения: ответ на устаревший запрос (неделю уже переключили, встречу уже сменили)
//  отбрасывается, а не перетирает свежий.
//
//  Список недели — два чтения фасада (C-016 v12 инв. 33, решение IR-146 в MEE-470): встречи
//  `meetings(from:to:)` и записи без встречи `adHocRecordings(from:to:)`; окно склеивает их в одну
//  таблицу (`MeetingRow.Kind`). Оба перечитываются по `meetingsChanged` (инв. 34). Выбранная
//  ad-hoc запись — карточка из одной записи; транскрипт — `latestTranscript(recordingId:)`.
//
//  Окно не держит копий дольше своей жизни: состояние живёт в контроллере, контроллер — пока
//  открыто окно (`MeetingsWindowPresenter`). Источник истины — фасад и его события.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

struct MeetingsWindowState: Equatable, Sendable {

    private(set) var week: MeetingsWeek
    private(set) var list: MeetingsListContent = .loading
    private(set) var adHocList: AdHocListContent = .loading
    /// Выбранная строка таблицы: встреча или запись без встречи.
    private(set) var selectedRow: MeetingRow.Kind?
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
    private(set) var adHocGeneration = 0
    private(set) var detailGeneration = 0
    private(set) var transcriptGeneration = 0
    private(set) var processingGeneration = 0

    init(now: Date) {
        week = MeetingsWeek.containing(now)
    }

    // MARK: Выбор

    var selectedMeetingId: UUID? {
        guard case .meeting(let meetingId) = selectedRow else { return nil }
        return meetingId
    }

    /// Выбранная запись без встречи из последнего ответа `adHocRecordings`. `nil` — выбрана
    /// не она или список ещё не пришёл.
    var selectedAdHoc: RecordingSummary? {
        guard case .adHoc(let recordingId) = selectedRow, case .loaded(let recordings) = adHocList else { return nil }
        return recordings.first { $0.recordingId == recordingId }
    }

    /// Записи карточки: у встречи — `MeetingDetail.recordings`, у ad-hoc строки — она одна.
    var selectedRecordings: [RecordingSummary] {
        switch selectedRow {
        case .meeting:
            guard case .loaded(let loaded) = detail else { return [] }
            return loaded.recordings
        case .adHoc:
            return selectedAdHoc.map { [$0] } ?? []
        case nil:
            return []
        }
    }

    // MARK: Входы пользователя

    /// Первые чтения при открытии окна.
    mutating func start() -> [MeetingsLoad] {
        [reloadList(), reloadAdHoc(), reloadProcessing()]
    }

    /// Ad-hoc строки живут в своей неделе, отдельного чтения записи по id у фасада нет —
    /// выбор ad-hoc строки при смене недели снимается. Выбор встречи остаётся (`meeting(id:)`).
    mutating func show(week newWeek: MeetingsWeek) -> [MeetingsLoad] {
        week = newWeek
        list = .loading
        adHocList = .loading
        var loads = [reloadList(), reloadAdHoc()]
        if case .adHoc = selectedRow { loads += select(row: nil) }
        return loads
    }

    /// Выбор строки списка. `nil` — снять выбор.
    mutating func select(row: MeetingRow.Kind?) -> [MeetingsLoad] {
        guard row != selectedRow else { return [] }
        selectedRow = row
        selectedRecordingId = nil
        transcriptSelection = .latest
        transcript = .none
        transcriptGeneration += 1
        actionError = nil
        switch row {
        case .meeting:
            detail = .loading
            return reloadDetail()
        case .adHoc(let recordingId):
            detail = .none
            detailGeneration += 1
            selectedRecordingId = recordingId
            return reloadTranscript(resetting: true)
        case nil:
            detail = .none
            detailGeneration += 1
            return []
        }
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

    /// Кнопка «Повторить загрузку»: перечитывается только то, что отказало (MEE-487 п. 8) —
    /// отказ карточки не сбрасывает загруженный список, и наоборот.
    mutating func retryReads() -> [MeetingsLoad] {
        var loads: [MeetingsLoad] = []
        if case .failed = list {
            list = .loading
            loads.append(reloadList())
        }
        if case .failed = adHocList {
            adHocList = .loading
            loads.append(reloadAdHoc())
        }
        if case .failed = detail {
            detail = .loading
            loads += reloadDetail()
        }
        if processingError != nil {
            loads.append(reloadProcessing())
        }
        return loads
    }

    /// «Повторить загрузку» у отказа чтения транскрипта (MEE-487 п. 6).
    mutating func retryTranscript() -> [MeetingsLoad] {
        guard case .failed = transcript else { return [] }
        return reloadTranscript(resetting: true)
    }

    // MARK: Генерации

    mutating func reloadList() -> MeetingsLoad {
        listGeneration += 1
        return .list(week: week, generation: listGeneration)
    }

    mutating func reloadAdHoc() -> MeetingsLoad {
        adHocGeneration += 1
        return .adHocList(week: week, generation: adHocGeneration)
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
        selectedRecordings.first { $0.recordingId == recordingId }?.transcripts.isEmpty == false
    }

    // MARK: Ответы фасада

    mutating func finishList(generation: Int, _ content: MeetingsListContent) {
        guard generation == listGeneration else { return }
        list = content
    }

    /// Выбранная ad-hoc запись пропала из ответа (удалена) — выбор снимается. Иначе, как у
    /// карточки встречи, перечитывается показанный транскрипт: так ad-hoc строка подхватывает
    /// транскрипт, готовность которого фасад сообщает только `meetingsChanged` (инв. 34 (в)).
    mutating func finishAdHoc(generation: Int, _ content: AdHocListContent) -> [MeetingsLoad] {
        guard generation == adHocGeneration else { return [] }
        adHocList = content
        guard case .adHoc(let recordingId) = selectedRow, case .loaded(let recordings) = content else { return [] }
        guard recordings.contains(where: { $0.recordingId == recordingId }) else { return select(row: nil) }
        return reloadTranscript(resetting: false)
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
            // Оба списка недели (инв. 34) и карточка встречи (признаки, записи, заголовки
            // транскриптов). Карточку ad-hoc записи обновляет ответ `adHocRecordings`.
            return [reloadList(), reloadAdHoc()] + reloadDetail()
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

    /// `transcriptChanged` — изменение **уже показанного** транскрипта (атрибуция, правка текста;
    /// C-016 инв. 15, 34): новая версия приходит `meetingsChanged`, не этим событием. Поэтому
    /// перечитывается только показанный текст, если это он, — без карточки (MEE-487 п. 7).
    private mutating func applyTranscriptChanged(_ transcriptId: UUID) -> [MeetingsLoad] {
        let isShown: Bool
        if case .loaded(let shown) = transcript {
            isShown = shown.header.id == transcriptId
        } else {
            // Текста ещё нет (загрузка, отказ) — показанной считается выбранная версия.
            isShown = transcriptSelection == .version(transcriptId)
        }
        return isShown ? reloadTranscript(resetting: false) : []
    }

    /// Очереди `pending`/`failed` перечитываются, когда в снимке сменились их счётчики (C-016 v13
    /// инв. 35 (б), (в)). Идущие задачи с долей блок берёт прямо из `runningJobs` снимка — ради
    /// них перечитывать нечего. `statusChanged` приходит на каждое событие очереди отдельно
    /// (инв. 35 (е)), поэтому переход `pending → running` виден по `pendingJobCount`, а
    /// `running → failed` — по `failedJobCount`.
    private mutating func applyStatusChanged(_ newStatus: AppStatus) -> [MeetingsLoad] {
        let previous = status
        apply(status: newStatus)
        guard status == newStatus else { return [] }
        let countersChanged = previous.map {
            $0.pendingJobCount != newStatus.pendingJobCount || $0.failedJobCount != newStatus.failedJobCount
        } ?? true
        return countersChanged ? [reloadProcessing()] : []
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

    /// `succeeded` — фасад поставил новую задачу. Иначе `error` — что показать; `nil` — отказ
    /// не `AppFacadeError` и не показывается (инв. 37), кнопка остаётся.
    mutating func finishRetry(jobId: UUID, succeeded: Bool, error: AppErrorView?) -> [MeetingsLoad] {
        guard retryInFlight == jobId else { return [] }
        retryInFlight = nil
        if succeeded {
            retriedJobIds.insert(jobId)
        } else {
            actionError = error
        }
        return [reloadProcessing()]
    }

    mutating func dismissActionError() {
        actionError = nil
    }
}
