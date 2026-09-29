//  MeetingsWindowPresentation — что окно «Встречи» рисует из `MeetingsWindowState` (MEE-474):
//  строки списка, заголовок недели, карточка встречи, записи. Чистые функции от состояния,
//  без SwiftUI; вид (`MeetingsWindowView.swift`) только перебирает эти значения. Транскрипт —
//  `TranscriptPresentation.swift`, состояние обработки — `ProcessingPresentation.swift`.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

// MARK: - Строка списка

/// Строка таблицы встреч. `Kind` — точка расширения (MEE-474): встреча `meetings(from:to:)` или
/// запись без встречи `adHocRecordings(from:to:)` (C-016 v12 инв. 33, MEE-487) — строки обоих
/// видов лежат в одной таблице и сортируются одной осью (`start`).
struct MeetingRow: Equatable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case meeting(UUID)
        /// Ручная запись без события (или чью встречу удалили) — по `recordingId`.
        case adHoc(recordingId: UUID)
    }

    /// Название ad-hoc записи — то же, что `ActiveSessionView.title` у фасада для такой сессии.
    static let adHocTitle = "Созвон без события"

    let kind: Kind
    let title: String
    let time: String
    let status: String
    let recording: String
    let transcript: String
    let cancelled: String
    /// Начало — для сортировки строк разных видов одной осью.
    let start: Date

    var id: String { MeetingsListPresentation.rowId(kind) }

    init(item: MeetingListItem) {
        kind = .meeting(item.meetingId)
        title = item.title.isEmpty ? "Без названия" : item.title
        time = MeetingsFormat.timeRange(item.start, item.end)
        status = MeetingsFormat.meetingStatus(item.status)
        recording = item.hasRecording ? "есть" : "—"
        transcript = item.hasTranscript ? "есть" : "—"
        cancelled = item.isCancelled ? "отменена" : ""
        start = item.start
    }

    /// «Есть транскрипт» — `!transcripts.isEmpty` (инв. 33).
    init(adHoc summary: RecordingSummary) {
        kind = .adHoc(recordingId: summary.recordingId)
        title = Self.adHocTitle
        time = MeetingsFormat.timeRange(summary.startedAt, summary.endedAt)
        status = MeetingsFormat.recordingStatus(summary.status).capitalizedFirst
        recording = "есть"
        transcript = summary.transcripts.isEmpty ? "—" : "есть"
        cancelled = ""
        start = summary.startedAt
    }
}

// MARK: - Список

struct MeetingsListPresentation: Equatable, Sendable {
    var weekTitle: String
    var rows: [MeetingRow] = []
    /// Заглушка на месте таблицы: загрузка, пустая неделя или ошибка списка встреч.
    var placeholder: String?
    var isError = false
    /// Отказ второго чтения (`adHocRecordings`) при загруженных встречах — строка под таблицей.
    var adHocError: String?
    var selectedRowId: String?

    init(state: MeetingsWindowState) {
        weekTitle = MeetingsFormat.weekTitle(state.week)
        selectedRowId = state.selectedRow.map(Self.rowId)
        switch state.list {
        case .loading:
            placeholder = "Загрузка…"
        case .failed(let error):
            placeholder = FacadeErrorText.line(error)
            isError = true
        case .loaded(let items):
            rows = items.map(MeetingRow.init(item:))
            switch state.adHocList {
            case .loaded(let recordings):
                rows += recordings.map(MeetingRow.init(adHoc:))
            case .failed(let error):
                adHocError = "\(MeetingRow.adHocTitle): " + FacadeErrorText.line(error)
            case .loading:
                break
            }
            // Равные начала — по id строки: порядок не прыгает между перечитываниями.
            rows.sort { ($0.start, $0.id) < ($1.start, $1.id) }
            if rows.isEmpty, adHocError == nil {
                placeholder = state.adHocList == .loading ? "Загрузка…" : "За эту неделю встреч нет"
            }
        }
    }

    static func rowId(_ kind: MeetingRow.Kind) -> String {
        switch kind {
        case .meeting(let meetingId): return "meeting.\(meetingId.uuidString)"
        case .adHoc(let recordingId): return "adHoc.\(recordingId.uuidString)"
        }
    }

    func kind(forRowId rowId: String?) -> MeetingRow.Kind? {
        guard let rowId else { return nil }
        return rows.first { $0.id == rowId }?.kind
    }
}

// MARK: - Карточка

struct RecordingRow: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
    let transcriptVersions: [TranscriptVersionRow]
    let processing: ProcessingLine?
}

struct TranscriptVersionRow: Equatable, Sendable, Identifiable {
    let id: UUID
    let title: String
}

struct MeetingCardPresentation: Equatable, Sendable {
    var title = ""
    var time = ""
    var status = ""
    var organizer: String?
    var attendees: [String] = []
    var recordings: [RecordingRow] = []
    var selectedRecordingId: UUID?
    /// Заглушка вместо карточки: ничего не выбрано, загрузка, нет встречи, ошибка.
    var placeholder: String?
    var isError = false
    var actionError: String?
    /// Отказ чтения очереди (`jobs(status:)`) — блок обработки неполон, карточка остаётся.
    var processingError: String?

    init(state: MeetingsWindowState) {
        switch state.selectedRow {
        case .meeting, nil:
            fillMeeting(state: state)
        case .adHoc:
            if let recording = state.selectedAdHoc {
                fill(adHoc: recording, state: state)
            } else if case .failed(let error) = state.adHocList {
                placeholder = FacadeErrorText.line(error)
                isError = true
            } else {
                placeholder = "Загрузка…"
            }
        }
        actionError = state.actionError.map(FacadeErrorText.line)
        processingError = state.processingError.map { "Очередь: " + FacadeErrorText.line($0) }
    }

    private mutating func fillMeeting(state: MeetingsWindowState) {
        switch state.detail {
        case .none: placeholder = "Выберите встречу"
        case .loading: placeholder = "Загрузка…"
        case .notFound: placeholder = "Встреча не найдена — возможно, удалена"
        case .failed(let error):
            placeholder = FacadeErrorText.line(error)
            isError = true
        case .loaded(let detail):
            fill(detail, state: state)
        }
    }

    private mutating func fill(_ detail: MeetingDetail, state: MeetingsWindowState) {
        let event = detail.meeting.event
        title = event.title.isEmpty ? "Без названия" : event.title
        time = MeetingsFormat.timeRange(event.start, event.end)
        status = MeetingsFormat.meetingStatus(detail.meeting.status) + (event.isCancelled ? " · отменена" : "")
        organizer = detail.organizer.map(Self.personTitle)
        attendees = detail.attendees.map(Self.personTitle)
        recordings = detail.recordings
            .sorted { $0.startedAt < $1.startedAt }
            .map { Self.recordingRow($0, state: state) }
        selectedRecordingId = state.selectedRecordingId
    }

    /// Ad-hoc запись: ни события, ни участников — карточка из одной записи.
    private mutating func fill(adHoc recording: RecordingSummary, state: MeetingsWindowState) {
        title = MeetingRow.adHocTitle
        time = MeetingsFormat.timeRange(recording.startedAt, recording.endedAt)
        status = MeetingsFormat.recordingStatus(recording.status).capitalizedFirst
        recordings = [Self.recordingRow(recording, state: state)]
        selectedRecordingId = state.selectedRecordingId
    }

    static func recordingRow(_ recording: RecordingSummary, state: MeetingsWindowState) -> RecordingRow {
        RecordingRow(
            id: recording.recordingId,
            title: MeetingsFormat.recordingTitle(recording),
            transcriptVersions: recording.transcripts
                .sorted { $0.createdAt > $1.createdAt }
                .map { TranscriptVersionRow(id: $0.id, title: MeetingsFormat.versionTitle($0)) },
            processing: recording.transcripts.isEmpty
                ? ProcessingLine.make(recording: recording, state: state)
                : nil
        )
    }

    static func personTitle(_ person: PersonRecord) -> String {
        let name = person.displayName.isEmpty ? (person.emails.first ?? "Без имени") : person.displayName
        return person.isMe ? "\(name) (я)" : name
    }
}

// MARK: - Форматы

enum MeetingsFormat {

    static func timeRange(_ start: Date, _ end: Date) -> String {
        let sameDay = MeetingsWeek.calendar.isDate(start, inSameDayAs: end)
        let tail = (sameDay ? time : dayMonthTime).string(from: end)
        return "\(weekdayDayMonthTime.string(from: start))–\(tail)"
    }

    /// Незавершённая запись (`endedAt == nil`) — правая граница открыта: «…».
    static func timeRange(_ start: Date, _ end: Date?) -> String {
        guard let end else { return "\(weekdayDayMonthTime.string(from: start))–…" }
        return timeRange(start, end)
    }

    static func weekTitle(_ week: MeetingsWeek) -> String {
        let lastDay = week.end.addingTimeInterval(-1)
        return "\(dayMonth.string(from: week.start)) – \(dayMonthYear.string(from: lastDay))"
    }

    static func recordingTitle(_ recording: RecordingSummary) -> String {
        let start = time.string(from: recording.startedAt)
        let end = recording.endedAt.map { "–" + time.string(from: $0) } ?? ""
        return "Запись \(start)\(end) · \(recordingStatus(recording.status))"
    }

    static func versionTitle(_ header: TranscriptHeader) -> String {
        let created = dayMonthTime.string(from: header.createdAt)
        return "\(created) · \(header.engine) \(header.modelVersion) · \(header.language)"
    }

    static func meetingStatus(_ status: MeetingStatus) -> String {
        switch status {
        case .scheduled: return "Запланирована"
        case .armed: return "Ждёт начала"
        case .awaitingSignal: return "Ждёт звонка"
        case .recording: return "Идёт запись"
        case .stopping: return "Останавливается"
        case .processing: return "Обработка"
        case .ready: return "Готова"
        case .failed: return "Ошибка"
        case .skipped: return "Пропущена"
        }
    }

    static func recordingStatus(_ status: RecordingStatus) -> String {
        switch status {
        case .recording: return "идёт запись"
        case .stopping: return "останавливается"
        case .finalized: return "записана"
        case .failed: return "сбой записи"
        }
    }

    /// Смещение от начала записи: «м:сс» до часа, «ч:мм:сс» после.
    static func offset(ms: Int) -> String {
        let total = max(0, ms / 1000)
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let seconds = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%d:%02d", minutes, seconds)
    }

    // MARK: Форматтеры

    // Создаются один раз (MEE-487 п. 9): `DateFormatter` дорог, а вид пересчитывает строки на
    // каждое изменение состояния. Пояс — `autoupdatingCurrent`: смена пояса в системе
    // подхватывается без пересоздания. Форматирование из разных потоков у `DateFormatter`
    // безопасно (macOS 10.9+); здесь его и так зовёт только главный поток вида.
    private static let weekdayDayMonthTime = formatter("EE d MMM, HH:mm")
    private static let dayMonthTime = formatter("d MMM, HH:mm")
    private static let time = formatter("HH:mm")
    private static let dayMonth = formatter("d MMM")
    private static let dayMonthYear = formatter("d MMM yyyy")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = format
        return formatter
    }
}

extension String {
    /// Первая буква заглавной: «идёт запись» → «Идёт запись».
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
