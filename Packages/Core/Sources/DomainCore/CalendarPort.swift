//  CalendarPort и ключ дедупликации — контракт C-005 (MEE-9), раздел «Определение»
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-289, прецедент формы — MEE-86). Реализацию порта пишет
//  модуль `calendar-hub` (Packages/Core/Sources/CalendarHub/); фейка `FakeCalendarPort`
//  в дереве нет — он предмет MEE-290.
//
//  Состав взят из раздела «Определение» этого контракта целиком: план MEE-288 §6 назвал
//  два имени (CalendarPort, CalendarChange), а «Определение» объявляет восемь, и пять
//  из них стоят в подписях самого порта. Сверено с разрешённым списком инварианта 9
//  (23 позиции): собственных имён контракта там ровно эти восемь.
//
//  `DedupKey.make(from:)` НЕ объявлен здесь, и это решение, а не пропуск: это функция,
//  а не тип, и её ответ задают инварианты 1—3 этого контракта — то есть поведение,
//  которое MEE-289 писать запрещено прямо. Цена названа в отчёте.
//
//  Порядок типов и порядок полей внутри типа — дословно по «Определению» контракта
//  (порядок значим: правило обхода C-001 §0.2 п. 9).

import Foundation

public struct CalendarSourceId: Hashable, Codable, Sendable {
    /// Идентификатор подключённого коннектора: "eventkit", "graph:work".
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public struct CalendarInfo: Codable, Equatable, Sendable {
    public let sourceId: CalendarSourceId
    public let calendarId: String  // идентификатор календаря внутри источника, как его отдал коннектор
    public let title: String
    public let isSelected: Bool    // включён ли календарь в синхронизацию
    public let isReadOnly: Bool

    public init(
        sourceId: CalendarSourceId,
        calendarId: String,
        title: String,
        isSelected: Bool,
        isReadOnly: Bool
    ) {
        self.sourceId = sourceId
        self.calendarId = calendarId
        self.title = title
        self.isSelected = isSelected
        self.isReadOnly = isReadOnly
    }
}

public enum CalendarSyncTrigger: String, Codable, Sendable {
    case schedule   // по таймеру опроса коннектора
    case wake       // пробуждение системы (сигнал приходит из PowerPort, C-008)
    case manual     // кнопка «Обновить» в UI
    case push       // уведомление от коннектора через сервис notify (C-006)
}

public enum CalendarError: Error, Codable, Equatable, Sendable {
    case notConfigured(sourceId: CalendarSourceId)
    case authorizationRequired(sourceId: CalendarSourceId)  // нужен повторный вход или право
    case transport(sourceId: CalendarSourceId, message: String)
    case protocolViolation(sourceId: CalendarSourceId, message: String)  // ответ не прошёл валидацию схемы
    case timeout(sourceId: CalendarSourceId, seconds: Int)
    case cancelled
}

public struct CalendarSyncResult: Codable, Equatable, Sendable {
    public let sourceId: CalendarSourceId
    public let trigger: CalendarSyncTrigger
    public let startedAt: Date
    public let finishedAt: Date
    public let upsertedCount: Int
    public let deletedCount: Int
    public let failure: CalendarError?   // nil — источник синхронизирован успешно

    public init(
        sourceId: CalendarSourceId,
        trigger: CalendarSyncTrigger,
        startedAt: Date,
        finishedAt: Date,
        upsertedCount: Int,
        deletedCount: Int,
        failure: CalendarError?
    ) {
        self.sourceId = sourceId
        self.trigger = trigger
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.upsertedCount = upsertedCount
        self.deletedCount = deletedCount
        self.failure = failure
    }
}

public enum CalendarChange: Equatable, Sendable {
    case upserted([MeetingEvent])   // события уже нормализованы и слиты (C-001)
    case deleted([UUID])            // MeetingEvent.id встреч, исчезнувших во всех источниках
}

public protocol CalendarPort: Sendable {
    func listSources() async -> [CalendarSourceId]
    func listCalendars(source: CalendarSourceId) async throws -> [CalendarInfo]
    func setSelectedCalendars(source: CalendarSourceId, calendarIds: [String]) async throws
    func events(from: Date, to: Date) async throws -> [MeetingEvent]
    func event(id: UUID) async throws -> MeetingEvent?
    func sync(trigger: CalendarSyncTrigger) async -> [CalendarSyncResult]
    func changes() -> AsyncStream<CalendarChange>
}

/// Ключ дедупликации. Две составляющие в каждой ветви: чем встреча опознаётся между
/// источниками и какое это её вхождение (инварианты 2 и 3).
public enum DedupKey: Hashable, Codable, Sendable {
    case joinUrl(String, startEpochSeconds: Int)   // нормализованный join-URL
    case icalUid(String, startEpochSeconds: Int)
    case organizerAndTime(organizerEmail: String, startEpochSeconds: Int)
}
