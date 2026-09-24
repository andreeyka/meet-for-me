//  FakeCalendarConnector — реализация `CalendarConnector` в памяти, C-006 §«Фейк для
//  тестов» (v9, IR-118, дословно называет это имя и это место — `DomainTestKit`).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Коннектор-сторона in-process шва — потребитель: `calendar-hub` (MEE-362), тесты группы
//  А/Б/В/Г перечня MEE-347. Форма — по образцу `FakeCalendarPort`/`FakePowerPort`: счётчики
//  через `PortCallLog`, поведение целиком задаёт тест, фейк не эталон поведения коннектора.
//
//  ВИСЯЩИЙ ВЫЗОВ (К9 перечня MEE-347, вход А — «настроен никогда не возвращаться»):
//  `hang(_:)` подвешивает метод на continuation, который тест никогда не резолвит; сам
//  вызов остаётся suspended до отмены объемлющей `Task` (хост гонкой с швом ожидания это
//  и делает). Отдельно от ошибок/результатов — третье состояние метода, не их комбинация.
//
//  `@unchecked Sendable` с замком: методы протокола — все `async`, но сам тип не актор
//  (тот же довод, что `FakeCalendarPort` — `CalendarConnector` объявлен `: Sendable`, замок
//  проще актора для чисто конфигурационного стораджа без реальной внутренней асинхронности).

import Foundation
import DomainCore

/// Метод коннектора — адрес заданного тестом отказа/зависания.
public enum CalendarConnectorMethod: String, Sendable, CaseIterable {
    case initialize, settingsSchema, configure, beginAuth, completeAuth
    case listCalendars, fetchEvents, fetchChanges, healthCheck, shutdown
}

public final class FakeCalendarConnector: CalendarConnector, @unchecked Sendable {

    public static let portName = "CalendarConnector"

    private let lock = NSLock()
    private let log: PortCallLog

    private var pluginInfo = PluginInfo(id: "fake", name: "Fake", version: "0.0")
    private var capabilities = ConnectorCapabilities(
        deltaSync: false, push: false, attendees: true, conference: true, auth: .none
    )
    private var listCalendarsResult: [ConnectorCalendar] = []
    private var fetchEventsResult: [MeetingEventPayload] = []
    private var fetchChangesResult: ChangeBatch?
    private var healthCheckResult = ConnectorHealth(status: .ok, message: nil, lastSuccessfulSyncAt: nil)
    private var settingsSchemaResult = Data("{}".utf8)
    private var authChallengeResult = AuthChallenge(authUrl: URL(string: "https://example.com")!, redirectScheme: "app")

    private var errors: [CalendarConnectorMethod: ConnectorError] = [:]
    private var hangingMethods: Set<CalendarConnectorMethod> = []
    private var shutdownCount = 0

    public init(log: PortCallLog = PortCallLog()) {
        self.log = log
    }

    public var callLog: PortCallLog { log }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    public func setInitializeResult(info: PluginInfo? = nil, capabilities: ConnectorCapabilities? = nil) {
        locked {
            if let info { self.pluginInfo = info }
            if let capabilities { self.capabilities = capabilities }
        }
    }

    public func setListCalendars(_ value: [ConnectorCalendar]) { locked { listCalendarsResult = value } }
    public func setFetchEvents(_ value: [MeetingEventPayload]) { locked { fetchEventsResult = value } }
    public func setFetchChanges(_ value: ChangeBatch) { locked { fetchChangesResult = value } }
    public func setHealthCheck(_ value: ConnectorHealth) { locked { healthCheckResult = value } }

    public func fail(_ method: CalendarConnectorMethod, with error: ConnectorError) {
        locked { errors[method] = error }
    }

    public func clearFailure(_ method: CalendarConnectorMethod) {
        locked { errors[method] = nil }
    }

    /// Метод не вернёт управление, пока тест сам не отменит объемлющую `Task` — К9 вход А.
    public func hang(_ method: CalendarConnectorMethod) {
        locked { hangingMethods.insert(method) }
    }

    public func callCount(_ method: CalendarConnectorMethod) -> Int {
        log.count(port: Self.portName, method: method.rawValue)
    }

    public var shutdownCallCount: Int { locked { shutdownCount } }

    /// К35/К36 — управляемая задержка: метод ждёт на воротах, пока тест не отпустит их
    /// `release(_:)`. `hang(_:)` без последующего `release(_:)` — тот же эффект, что было у
    /// «никогда не возвращается» (К9 вход А): тест просто не вызывает `release`.
    private var gateContinuations: [CalendarConnectorMethod: [CheckedContinuation<Void, Never>]] = [:]

    private func hangOrGate(_ method: CalendarConnectorMethod) async throws {
        guard locked({ hangingMethods.contains(method) }) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            locked { gateContinuations[method, default: []].append(continuation) }
        }
    }

    /// Отпускает все вызовы этого метода, ждущие на воротах (К35/К36). Метод, отпущенный
    /// без предшествующего `hang(_:)`, не имеет ждущих — вызов безопасен, эффекта нет.
    public func release(_ method: CalendarConnectorMethod) {
        let waiting = locked { () -> [CheckedContinuation<Void, Never>] in
            let list = gateContinuations[method] ?? []
            gateContinuations[method] = []
            return list
        }
        for continuation in waiting { continuation.resume() }
    }

    private func failureOrNil(_ method: CalendarConnectorMethod) -> ConnectorError? {
        locked { errors[method] }
    }

    // MARK: - CalendarConnector

    public func initialize(
        host: ConnectorHostServices, connectorInstanceId: String
    ) async throws -> (PluginInfo, ConnectorCapabilities) {
        log.record(
            port: Self.portName, method: CalendarConnectorMethod.initialize.rawValue, arguments: [connectorInstanceId]
        )
        try await hangOrGate(.initialize)
        if let error = failureOrNil(.initialize) { throw error }
        return locked { (pluginInfo, capabilities) }
    }

    public func settingsSchema() async throws -> Data {
        log.record(port: Self.portName, method: CalendarConnectorMethod.settingsSchema.rawValue)
        try await hangOrGate(.settingsSchema)
        if let error = failureOrNil(.settingsSchema) { throw error }
        return locked { settingsSchemaResult }
    }

    public func configure(settings: Data) async throws {
        log.record(port: Self.portName, method: CalendarConnectorMethod.configure.rawValue)
        try await hangOrGate(.configure)
        if let error = failureOrNil(.configure) { throw error }
    }

    public func beginAuth() async throws -> AuthChallenge {
        log.record(port: Self.portName, method: CalendarConnectorMethod.beginAuth.rawValue)
        try await hangOrGate(.beginAuth)
        if let error = failureOrNil(.beginAuth) { throw error }
        return locked { authChallengeResult }
    }

    public func completeAuth(callbackUrl: URL) async throws -> String? {
        log.record(port: Self.portName, method: CalendarConnectorMethod.completeAuth.rawValue)
        try await hangOrGate(.completeAuth)
        if let error = failureOrNil(.completeAuth) { throw error }
        return nil
    }

    public func listCalendars() async throws -> [ConnectorCalendar] {
        log.record(port: Self.portName, method: CalendarConnectorMethod.listCalendars.rawValue)
        try await hangOrGate(.listCalendars)
        if let error = failureOrNil(.listCalendars) { throw error }
        return locked { listCalendarsResult }
    }

    public func fetchEvents(from: Date, to: Date, calendarIds: [String]) async throws -> [MeetingEventPayload] {
        log.record(
            port: Self.portName, method: CalendarConnectorMethod.fetchEvents.rawValue,
            arguments: [String(from.timeIntervalSince1970), String(to.timeIntervalSince1970)] + calendarIds
        )
        try await hangOrGate(.fetchEvents)
        if let error = failureOrNil(.fetchEvents) { throw error }
        return locked { fetchEventsResult }
    }

    public func fetchChanges(cursor: String?, calendarIds: [String]) async throws -> ChangeBatch {
        log.record(
            port: Self.portName, method: CalendarConnectorMethod.fetchChanges.rawValue,
            arguments: [cursor ?? "nil"] + calendarIds
        )
        try await hangOrGate(.fetchChanges)
        if let error = failureOrNil(.fetchChanges) { throw error }
        guard let result = locked({ fetchChangesResult }) else {
            preconditionFailure("setFetchChanges(_:) не вызван тестом до fetchChanges")
        }
        return result
    }

    public func healthCheck() async throws -> ConnectorHealth {
        log.record(port: Self.portName, method: CalendarConnectorMethod.healthCheck.rawValue)
        try await hangOrGate(.healthCheck)
        if let error = failureOrNil(.healthCheck) { throw error }
        return locked { healthCheckResult }
    }

    public func shutdown() async {
        log.record(port: Self.portName, method: CalendarConnectorMethod.shutdown.rawValue)
        locked { shutdownCount += 1 }
    }
}
