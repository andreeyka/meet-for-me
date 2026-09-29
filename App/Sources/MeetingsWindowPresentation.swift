//  MeetingsWindowPresentation — что окно «Встречи» рисует из `MeetingsWindowState` (MEE-474):
//  строки списка, заголовок недели, карточка встречи, записи. Чистые функции от состояния,
//  без SwiftUI; вид (`MeetingsWindowView.swift`) только перебирает эти значения. Транскрипт —
//  `TranscriptPresentation.swift`, состояние обработки — `ProcessingPresentation.swift`.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

// MARK: - Строка списка

/// Строка таблицы встреч. `Kind` — точка расширения: ad-hoc запись (ручной старт без события)
/// ляжет сюда своим случаем, когда фасад начнёт её отдавать (IR-146, MEE-470). Сейчас ни один
/// запрос чтения C-016 её не возвращает, строки нет.
struct MeetingRow: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case meeting(UUID)
    }

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
}

// MARK: - Список

struct MeetingsListPresentation: Equatable, Sendable {
    var weekTitle: String
    var rows: [MeetingRow] = []
    /// Заглушка на месте таблицы: загрузка, пустая неделя или ошибка.
    var placeholder: String?
    var isError = false
    var selectedRowId: String?

    init(state: MeetingsWindowState) {
        weekTitle = MeetingsFormat.weekTitle(state.week)
        selectedRowId = state.selectedMeetingId.map { MeetingRow.Kind.meeting($0) }.map(Self.rowId)
        switch state.list {
        case .loading:
            placeholder = "Загрузка…"
        case .failed(let error):
            placeholder = FacadeErrorText.line(error)
            isError = true
        case .loaded(let items):
            rows = items.map(MeetingRow.init(item:)).sorted { $0.start < $1.start }
            if rows.isEmpty { placeholder = "За эту неделю встреч нет" }
        }
    }

    static func rowId(_ kind: MeetingRow.Kind) -> String {
        switch kind {
        case .meeting(let meetingId): return "meeting.\(meetingId.uuidString)"
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
        actionError = state.actionError.map(FacadeErrorText.line)
        processingError = state.processingError.map { "Очередь: " + FacadeErrorText.line($0) }
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
            .map { recording in
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
        selectedRecordingId = state.selectedRecordingId
    }

    static func personTitle(_ person: PersonRecord) -> String {
        let name = person.displayName.isEmpty ? (person.emails.first ?? "Без имени") : person.displayName
        return person.isMe ? "\(name) (я)" : name
    }
}

// MARK: - Форматы

enum MeetingsFormat {

    static func timeRange(_ start: Date, _ end: Date) -> String {
        let day = formatter("EE d MMM, HH:mm").string(from: start)
        let sameDay = MeetingsWeek.calendar.isDate(start, inSameDayAs: end)
        let tail = formatter(sameDay ? "HH:mm" : "d MMM, HH:mm").string(from: end)
        return "\(day)–\(tail)"
    }

    static func weekTitle(_ week: MeetingsWeek) -> String {
        let lastDay = week.end.addingTimeInterval(-1)
        return "\(formatter("d MMM").string(from: week.start)) – \(formatter("d MMM yyyy").string(from: lastDay))"
    }

    static func recordingTitle(_ recording: RecordingSummary) -> String {
        let start = formatter("HH:mm").string(from: recording.startedAt)
        let end = recording.endedAt.map { "–" + formatter("HH:mm").string(from: $0) } ?? ""
        return "Запись \(start)\(end) · \(recordingStatus(recording.status))"
    }

    static func versionTitle(_ header: TranscriptHeader) -> String {
        let created = formatter("d MMM, HH:mm").string(from: header.createdAt)
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

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = .current
        formatter.dateFormat = format
        return formatter
    }
}
