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
//  `DedupKey.make(from:)` не был объявлен MEE-289 — это функция, а не тип, и её ответ
//  задают инварианты 1—3, то есть поведение, которое та задача писать запрещала прямо.
//  Тело добавлено MEE-352 (IR-118, C-005 v8 — инварианты 1—3 не менялись с v4): приоритет
//  ветвей и вход времени — инвариант 2; `startEpochSeconds` — округление ВНИЗ до минуты
//  (инвариант 3, а не усечение к нулю — на отрицательных `timeIntervalSince1970` это разные
//  числа); диапазон `start` не проверяется здесь второй раз — `MeetingEvent.init` уже сделал
//  это по C-001 §0.2 п. 9, и `Int(...)` в `startEpochSeconds(for:)` безопасен по построению
//  (замечание к инварианту 3). Нормализация join-URL — шесть шагов «Определения» дословно.
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

    /// Инвариант 2: приоритет ветвей строгий — `joinUrl` первой составляющей, затем
    /// непустой `icalUid`, затем `organizer.email`; ни одна не подошла — `nil` (событие не
    /// дедуплицируется). `startEpochSeconds` — вторая составляющая — входит в КАЖДУЮ ветвь
    /// (инвариант 3), не в одну.
    public static func make(from event: MeetingEvent) -> DedupKey? {
        let startEpochSeconds = Self.startEpochSeconds(for: event.start)
        if let joinUrl = event.conference?.joinUrl {
            return .joinUrl(Self.normalizedJoinURL(joinUrl), startEpochSeconds: startEpochSeconds)
        }
        if let icalUid = event.icalUid, !icalUid.isEmpty {
            return .icalUid(icalUid, startEpochSeconds: startEpochSeconds)
        }
        if let organizerEmail = event.organizer?.email {
            return .organizerAndTime(organizerEmail: organizerEmail, startEpochSeconds: startEpochSeconds)
        }
        return nil
    }

    /// Инвариант 3: округление ВНИЗ до минуты — `.rounded(.down)`, не `Int(...)` усечением
    /// к нулю: на отрицательном `timeIntervalSince1970` (даты до 1970 года) это разные
    /// числа, а «вниз» здесь значит «дальше от нуля», не «ближе». `Int(...)` не падает: по
    /// диапазону `MeetingEvent.init` (C-001 §0.2 п. 9) `date` уже представим, и частное на
    /// 60 остаётся в представимом для `Int` диапазоне с большим запасом.
    private static func startEpochSeconds(for date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 60).rounded(.down)) * 60
    }

    /// Шесть шагов «Определения» дословно и по порядку. `joinUrl` уже проверен
    /// `Conference.validate()` абсолютным `https` URL с хостом (C-005) — здесь только
    /// нормализация, не повторная проверка.
    private static func normalizedJoinURL(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        let scheme = (components.scheme ?? "").lowercased()
        var host = (components.host ?? "").lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst("www.".count)
        }
        let defaultPort = scheme == "https" ? 443 : nil
        let port = components.port == defaultPort ? nil : components.port
        var path = components.path
        if path.hasSuffix("/") {
            path.removeLast()
        }
        let portSuffix = port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portSuffix)\(path)"
    }
}
