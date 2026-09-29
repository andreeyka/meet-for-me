//  MeetingsWindowTypes — значения, из которых состоит состояние окна «Встречи» (MEE-474): неделя,
//  чтения, которые модель просит у фасада, и содержимое областей окна. Вынесено из
//  `MeetingsWindowModel.swift` по объёму файла (`file_length`), логики здесь нет.
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
    /// `adHocRecordings(from:to:)` — записи без встречи (C-016 v12 инв. 33).
    case adHocList(week: MeetingsWeek, generation: Int)
    /// `meeting(id:)`.
    case detail(meetingId: UUID, generation: Int)
    /// `latestTranscript(recordingId:)` при `.latest`, иначе `transcript(id:)`.
    case transcript(recordingId: UUID, selection: TranscriptSelection, generation: Int)
    /// `status()` и `jobs(status:)` для `.pending` и `.failed`.
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

/// Записи без встречи за неделю — вторая половина списка (строки `MeetingRow.Kind.adHoc`).
enum AdHocListContent: Equatable, Sendable {
    case loading
    case loaded([RecordingSummary])
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

/// Снимок очереди для блока «Состояние обработки»: `jobs(status:)` — по записи через
/// `JobPayload`. Идущие задачи с долей — из `status().runningJobs` (C-016 v13 инв. 35), не отсюда.
struct ProcessingSnapshot: Equatable, Sendable {
    var pending: [Job] = []
    var failed: [Job] = []
}
