//  Swift-зеркало C-006 §6 (для in-process коннекторов) — контракт C-006 (MEE-10).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  MEE-346. Типы объявлены дословно по тексту §6: подписи, поля и порядок случаев
//  `ConnectorError` взяты из блока Swift контракта без изменений — ни один тип и ни одна
//  подпись здесь не выбраны реализатором. `MeetingEventPayload` (§6.1) — отдельный файл,
//  `MeetingEventPayload.swift`: у него собственные инварианты и собственная история.

import Foundation

public struct PluginInfo: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String

    public init(id: String, name: String, version: String) {
        self.id = id
        self.name = name
        self.version = version
    }
}

public struct ConnectorCapabilities: Codable, Equatable, Sendable {
    public enum Auth: String, Codable, Sendable { case none, oauth }

    public let deltaSync: Bool
    public let push: Bool
    public let attendees: Bool
    public let conference: Bool
    public let auth: Auth

    public init(deltaSync: Bool, push: Bool, attendees: Bool, conference: Bool, auth: Auth) {
        self.deltaSync = deltaSync
        self.push = push
        self.attendees = attendees
        self.conference = conference
        self.auth = auth
    }
}

public struct ConnectorHealth: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case ok, degraded, failed }

    public let status: Status
    public let message: String?
    public let lastSuccessfulSyncAt: Date?

    public init(status: Status, message: String?, lastSuccessfulSyncAt: Date?) {
        self.status = status
        self.message = message
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
    }
}

public struct AuthChallenge: Codable, Equatable, Sendable {
    public let authUrl: URL
    public let redirectScheme: String

    public init(authUrl: URL, redirectScheme: String) {
        self.authUrl = authUrl
        self.redirectScheme = redirectScheme
    }
}

public struct ConnectorCalendar: Codable, Equatable, Sendable {
    public let calendarId: String
    public let title: String
    public let isReadOnly: Bool

    public init(calendarId: String, title: String, isReadOnly: Bool) {
        self.calendarId = calendarId
        self.title = title
        self.isReadOnly = isReadOnly
    }
}

public struct ChangeBatch: Codable, Equatable, Sendable {
    public let events: [MeetingEventPayload]   // id здесь нет по построению типа
    public let deletedExternalIds: [String]
    public let cursor: String
    public let resetRequired: Bool

    public init(
        events: [MeetingEventPayload], deletedExternalIds: [String], cursor: String, resetRequired: Bool
    ) {
        self.events = events
        self.deletedExternalIds = deletedExternalIds
        self.cursor = cursor
        self.resetRequired = resetRequired
    }
}

/// Случаи и порядок — §6 дословно; отображение в коды JSON-RPC и `CalendarError` (C-005) —
/// §5.1, одна таблица на все три словаря, своего отображения ни одна сторона не пишет.
public enum ConnectorError: Error, Codable, Equatable, Sendable {
    case authorizationRequired
    case notConfigured
    case rateLimited(retryAfterSeconds: Int)
    case cursorInvalid
    case upstreamUnavailable(message: String)
    case protocolViolation(message: String)
}

public enum HostNotificationKind: String, Codable, Sendable {
    case changesAvailable, authExpired, configInvalid
}

public enum LogLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

/// Сервисы, которые хост предоставляет коннектору.
public protocol ConnectorHostServices: Sendable {
    func secretGet(key: String) async throws -> String?
    func secretSet(key: String, value: String?) async throws
    func log(_ level: LogLevel, _ message: String)
    func notify(_ kind: HostNotificationKind, detail: String?)
}

/// Зеркало протокола плагина для in-process реализаций (calendar-eventkit).
public protocol CalendarConnector: Sendable {
    func initialize(host: ConnectorHostServices,
                    connectorInstanceId: String) async throws -> (PluginInfo, ConnectorCapabilities)
    func settingsSchema() async throws -> Data          // JSON Schema как UTF-8 JSON
    func configure(settings: Data) async throws         // JSON-объект как UTF-8 JSON
    func beginAuth() async throws -> AuthChallenge
    func completeAuth(callbackUrl: URL) async throws -> String?   // метка аккаунта или nil
    func listCalendars() async throws -> [ConnectorCalendar]
    func fetchEvents(from: Date, to: Date, calendarIds: [String]) async throws -> [MeetingEventPayload]
    func fetchChanges(cursor: String?, calendarIds: [String]) async throws -> ChangeBatch
    func healthCheck() async throws -> ConnectorHealth
    func shutdown() async
}
