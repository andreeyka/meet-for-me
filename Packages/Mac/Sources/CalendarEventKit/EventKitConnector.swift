//  EventKitConnector — реализация `CalendarConnector` (Swift-зеркало C-006 §6, MEE-346)
//  поверх EventKit. Единственный публичный тип модуля.
//
//  Модуль: calendar-eventkit · Владелец: DEV-1 · Слой: плагин (адаптер системного API)
//
//  Право `.calendars` проверяется здесь, через `PermissionsPort` (C-007), ДО каждого
//  обращения к `EventKitGateway` — шов авторизации не несёт (MEE-339, раздел «Шов»).

import DomainCore
import Foundation

public actor EventKitConnector: CalendarConnector {

    private let gateway: EventKitGateway
    private let permissions: PermissionsPort
    /// IR-118 (MEE-348) закрыт C-009 v11: развилку Р4 (своя таблица доменов) заменяет вызов
    /// `PlatformResolver.resolve(text:source:)` (не `resolve(event:)` — тот требует готовый
    /// `MeetingEvent` с `id`, которого у коннектора нет: `id` назначает только хост, C-006
    /// §6.1). Инжектируется составным корнем `app-ui` (не C-016 — C-016 сам отказывается быть
    /// чем-либо большим фасада UI, C-009 v11), не строится изнутри модуля — тем же приёмом,
    /// что `permissions`.
    private let platformResolver: PlatformResolver

    private var host: ConnectorHostServices?
    private var connectorInstanceId = ""
    private var isInitialized = false

    /// Состояние для `healthCheck` (Р5) — обновляется только вызовами `EventKitGateway`
    /// (`listCalendars`/`fetchEvents`), не проверками права: К25 разбирает право и «последний
    /// вызов» как две независимые оси.
    private var lastGatewaySuccessAt: Date?
    private var lastGatewayFailureMessage: String?

    /// Продовый инициализатор: реальный шов поверх `EKEventStore`. `EventKitGateway` — тип
    /// модуля (не публичный за его границей), поэтому инициализатор с ним параметром не может
    /// быть публичным — этот, единственный публичный вход, подставляет его сам. `platformResolver`
    /// — реализацию (`detector`) собирает составной корень приложения, не этот модуль.
    public init(permissions: PermissionsPort, platformResolver: PlatformResolver) {
        self.init(gateway: EventKitCoreGateway(), permissions: permissions, platformResolver: platformResolver)
    }

    /// Полный инициализатор — виден тестам через `@testable import`, шов подставляется.
    init(gateway: EventKitGateway, permissions: PermissionsPort, platformResolver: PlatformResolver) {
        self.gateway = gateway
        self.permissions = permissions
        self.platformResolver = platformResolver
    }

    // MARK: - CalendarConnector

    public func initialize(
        host: ConnectorHostServices, connectorInstanceId: String
    ) async throws -> (PluginInfo, ConnectorCapabilities) {
        self.host = host
        self.connectorInstanceId = connectorInstanceId
        isInitialized = true
        let info = PluginInfo(id: "com.meetforme.calendar-eventkit", name: "EventKit Calendar", version: "1.0.0")
        // Р1–Р4: auth == .none (TCC, не OAuth), deltaSync == false (EventKit не даёт сетевого
        // курсора), push == false («Запрещено: собственное расписание опроса»), attendees и
        // conference — true (EventKit отдаёт участников; conference — эвристика Р4).
        let capabilities = ConnectorCapabilities(
            deltaSync: false, push: false, attendees: true, conference: true, auth: .none
        )
        return (info, capabilities)
    }

    public func settingsSchema() async throws -> Data {
        // Р6: EventKit не берёт пользовательских настроек уровня подключения — пустая схема.
        try JSONSerialization.data(withJSONObject: ["type": "object", "properties": [String: Any]()])
    }

    public func configure(settings: Data) async throws {
        // Р6: настраивать нечего — принимает любой вход, проходящий пустую объектную схему,
        // и не бросает никогда (К9).
    }

    public func beginAuth() async throws -> AuthChallenge {
        // К2, инвариант 7 C-006: недостижимо при auth == .none — не открывает браузер.
        throw ConnectorError.protocolViolation(message: "auth == .none — beginAuth недостижим")
    }

    public func completeAuth(callbackUrl: URL) async throws -> String? {
        throw ConnectorError.protocolViolation(message: "auth == .none — completeAuth недостижим")
    }

    public func listCalendars() async throws -> [ConnectorCalendar] {
        try requireInitialized()
        try await requirePermission()
        let raw = try await callGateway { try await self.gateway.calendars() }
        return raw.map { ConnectorCalendar(calendarId: $0.calendarId, title: $0.title, isReadOnly: $0.isReadOnly) }
    }

    public func fetchEvents(from: Date, to: Date, calendarIds: [String]) async throws -> [MeetingEventPayload] {
        try requireInitialized()
        try await requirePermission()
        let raw = try await callGateway { try await self.gateway.events(from: from, to: to, calendarIds: calendarIds) }
        // Развилка Р9: окно `[from, to)` полуоткрыто и фильтр `calendarIds` проверяются здесь,
        // а не только переданы шву, — предикат `EKEventStore` фильтрует по пересечению
        // интервала, не гарантирует ровно эту границу (см. `RawEvent.calendarId`).
        let idSet = Set(calendarIds)
        let windowed = raw.filter { idSet.contains($0.calendarId) && $0.start >= from && $0.start < to }
        do {
            // Развилка Р8: одно невалидное событие роняет ВЕСЬ вызов, не только себя — тот же
            // приём, каким `Array<Decodable>` останавливается на первом элементе (К15).
            return try windowed.map(buildPayload)
        } catch let error as DomainValidationError {
            throw ConnectorError.protocolViolation(message: error.description)
        }
    }

    public func fetchChanges(cursor: String?, calendarIds: [String]) async throws -> ChangeBatch {
        // К3, Р2, инвариант 6 C-006: недостижимо при deltaSync == false — не трогает шов.
        throw ConnectorError.protocolViolation(message: "deltaSync == false — fetchChanges недостижим")
    }

    public func healthCheck() async throws -> ConnectorHealth {
        // Р5: право и «последний вызов шва» — две независимые оси, четыре комбинации (К25).
        let status = await permissions.status(of: .calendars)
        guard status == .granted else {
            return ConnectorHealth(
                status: .failed, message: "право .calendars не выдано: \(status)",
                lastSuccessfulSyncAt: lastGatewaySuccessAt
            )
        }
        if let failureMessage = lastGatewayFailureMessage {
            return ConnectorHealth(status: .failed, message: failureMessage, lastSuccessfulSyncAt: lastGatewaySuccessAt)
        }
        return ConnectorHealth(status: .ok, message: nil, lastSuccessfulSyncAt: lastGatewaySuccessAt)
    }

    public func shutdown() async {
        isInitialized = false
        host = nil
    }

    // MARK: - Право и порядок вызовов

    private func requireInitialized() throws {
        // К4: проверка порядка — ДО проверки права (см. вызывающие методы выше), иначе
        // реализация без проверки порядка поймала бы authorizationRequired путём К21 и
        // замаскировала бы отсутствие проверки тем же зелёным цветом (перечень, К4).
        guard isInitialized else {
            throw ConnectorError.protocolViolation(message: "вызов до initialize()")
        }
    }

    private func requirePermission() async throws {
        // К21–К23: любой статус, кроме .granted (включая .unknown/.unavailable — «Следствие»
        // к К23: ветвление ровно на два случая), блокирует ДО обращения к EventKitGateway.
        guard await permissions.status(of: .calendars) == .granted else {
            throw ConnectorError.authorizationRequired
        }
    }

    // MARK: - Шов

    private func callGateway<Value>(_ body: () async throws -> Value) async throws -> Value {
        do {
            let value = try await body()
            lastGatewaySuccessAt = Date()
            lastGatewayFailureMessage = nil
            return value
        } catch let error as EventKitGatewayError {
            let message: String
            switch error {
            case .looksLikePermissionLoss(let text):
                message = text
                lastGatewayFailureMessage = message
                host?.log(.error, message)
                throw ConnectorError.authorizationRequired
            case .other(let text):
                message = text
                lastGatewayFailureMessage = message
                host?.log(.error, message)
                throw ConnectorError.upstreamUnavailable(message: message)
            }
        }
    }

    // MARK: - Нормализация (IR-116)

    private func buildPayload(from raw: RawEvent) throws -> MeetingEventPayload {
        let timeZoneIdentifier = EventNormalizer.ianaTimeZoneIdentifier(raw.timeZoneIdentifier)
        let bounds = raw.isAllDay
            ? EventNormalizer.allDayBounds(rawStart: raw.start, rawEnd: raw.end, timeZoneIdentifier: timeZoneIdentifier)
            : (start: raw.start, end: raw.end)
        let conference = resolveConference(location: raw.location, bodyText: raw.notes)
        return try MeetingEventPayload(
            sourceConnectorId: connectorInstanceId,
            externalId: raw.externalId,
            icalUid: raw.icalUid,
            title: raw.title,
            start: bounds.start,
            end: bounds.end,
            timeZone: timeZoneIdentifier,
            isAllDay: raw.isAllDay,
            isCancelled: raw.isCancelled,
            organizer: try raw.organizer.map(buildPerson),
            attendees: try raw.attendees.map(buildAttendee),
            location: raw.location,
            bodyText: raw.notes,
            conference: conference,
            lastModified: raw.lastModified
        )
    }

    /// IR-118/К16, C-009 v11: порядок разбора события — `conference → location → bodyText`,
    /// первое совпадение побеждает (C-009 §2, инв. 3). У EventKit-источника структурного поля
    /// `conference` нет (сама причина, по которой Р4 вообще была нужна) — коннектор проверяет
    /// оставшиеся два поля в том же относительном порядке: `location`, затем `bodyText`.
    private func resolveConference(location: String?, bodyText: String?) -> MeetingEvent.Conference? {
        let joinInfo = location.flatMap { platformResolver.resolve(text: $0, source: .location) }
            ?? bodyText.flatMap { platformResolver.resolve(text: $0, source: .bodyText) }
        return joinInfo.flatMap { try? MeetingEvent.Conference(
            provider: $0.provider, joinUrl: $0.joinUrl, meetingId: $0.meetingId, passcode: $0.passcode
        ) }
    }

    private func buildPerson(from raw: RawPerson) throws -> MeetingEvent.Person {
        try MeetingEvent.Person(name: raw.name, email: EventNormalizer.normalizedEmail(raw.email))
    }

    private func buildAttendee(from raw: RawAttendee) throws -> MeetingEvent.Attendee {
        try MeetingEvent.Attendee(
            person: try buildPerson(from: raw.person),
            responseStatus: raw.responseStatus.mapped,
            isOptional: raw.isOptional
        )
    }
}

extension RawResponseStatus {
    var mapped: MeetingEvent.Attendee.ResponseStatus {
        switch self {
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .needsAction: return .needsAction
        case .unknown: return .unknown
        }
    }
}
