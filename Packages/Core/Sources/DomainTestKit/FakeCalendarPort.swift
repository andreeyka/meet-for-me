//  FakeCalendarPort — реализация `CalendarPort` в памяти, C-005 §«Фейк для тестов».
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Состав управляющей поверхности взят из §«Фейк для тестов» C-005 дословно, а не из
//  перечисления §6 плана MEE-288: задать набор событий НА ИСТОЧНИК; заставить `sync` вернуть
//  заданный `CalendarError` для ВЫБРАННОГО источника; вручную протолкнуть `CalendarChange`
//  в поток `changes()`; ПОСЧИТАТЬ ЧИСЛО ВЫЗОВОВ `sync` ПО ТРИГГЕРАМ. Последнего §6 плана не
//  называет вовсе — найдено чтением контракта.
//
//  ФЕЙК НЕ ЭТАЛОН ПОВЕДЕНИЯ ПОРТА, и вход он не приводит ни к чему — тот же довод и та же
//  форма, что у `FakeProcessMonitorPort` (C-009) и `FakePowerPort` (C-008). Отсюда два
//  следствия, названные прямо, потому что молчание о них читается как их отсутствие:
//
//  1. `events(from:to:)` отдаёт события окна В ПОРЯДКЕ, ЗАДАННОМ ТЕСТОМ, и не сортирует их
//     ни по чему. Инвариант 6 контракта («по возрастанию `start`, при равенстве по `id`») —
//     обязанность `calendar-hub`, и фейк её не исполняет и не проверяет. Сортируй фейк сам,
//     потребитель, молча опирающийся на порядок порта, был бы зелен здесь и красен на живой
//     реализации, отдавшей тот же набор иначе, — правило 7 проекта в чистом виде.
//  2. Дедупликации фейк не делает ни одной: `DedupKey.make(from:)` в дереве не объявлена
//     (её держит П4, MEE-290 §2), и инварианты 1—5 контракта здесь не исполняются ничем.
//     Два события с равным ключом остаются двумя событиями.
//
//  ОКНО `events(from:to:)` НАЗВАНО ЯВНО, потому что контракт его не определяет: событие
//  входит в ответ тогда и только тогда, когда `from <= event.start && event.start < to`.
//  Правило полуоткрыто справа и читается по `start`, а не по пересечению с `[from, to)`:
//  так тест, подающий событие, точно знает, войдёт оно или нет, и граница проверяема
//  двумя вызовами вместо перебора. Это решение фейка, а не утверждение о порте.
//
//  ШЕСТЬ МЕТОДОВ УПРАВЛЯЮЩЕЙ ПОВЕРХНОСТИ ИСТОЧНИКА добавлены MEE-355 (IR-120, MEE-354,
//  C-005 v8 §«Фейк для тестов» дословно): канонические `AuthChallenge`/`ConnectorHealth`/
//  схема настроек (`Data`) на источник для `beginAuth`/`healthCheck`/`settingsSchema` —
//  умолчания НЕТ НАМЕРЕННО, тот же довод, что у `FakePowerPort(snapshot:)` («умолчания нет
//  намеренно» — пустого значения не существует, и тест обязан задать его сам): вызов на
//  источнике без заданного канонического значения — `preconditionFailure`, а не тихая
//  подделка. `completeAuth` в этот список не входит — контракт не даёт тесту канонического
//  значения на его ответ, только отказ, и фейк отвечает `nil`, пока не отказывает. Отказ
//  любого из пяти бросающих методов (`beginAuth`, `completeAuth`, `settingsSchema`,
//  `configure`, `healthCheck`) — заданной `CalendarError`, на ВЫБРАННОМ источнике или на
//  всяком (`source: nil`), тем же приёмом, что `failSync(with:for:)`. `stop()` — только
//  счётчик вызовов: он объявлен без `throws`, и фейку бросать ему нечем.
//
//  `configuredSettings(for:)` — та же наблюдаемость, что `selectedCalendars(for:)` у
//  `setSelectedCalendars`, тем же доводом: контракт её не называет пофамильно, но без неё
//  `configure` нечем проверить, кроме «не упал».
//
//  `@unchecked Sendable` с замком, а не актор: `CalendarPort` объявлен `: Sendable`,
//  а его методы — не `async` целиком (`changes()` синхронен), и актором протокол не покрыть.

import Foundation
import DomainCore

/// Один из пяти бросающих методов управляющей поверхности источника (C-005 v8 §«Фейк для
/// тестов»). `stop()` сюда не входит: он объявлен без `throws`, и фейку бросать ему нечем.
public enum CalendarPortThrowingMethod: String, Sendable, CaseIterable {
    case beginAuth, completeAuth, settingsSchema, configure, healthCheck
}

/// Фейк календарного порта. Всё поведение задаёт тест.
public final class FakeCalendarPort: CalendarPort, @unchecked Sendable {

    /// Имя порта в журнале вызовов — имя из контракта, а не имя фейка.
    public static let portName = "CalendarPort"

    private let lock = NSLock()
    private let log: PortCallLog

    private var sources: [CalendarSourceId] = []
    private var eventsBySource: [String: [MeetingEvent]] = [:]
    private var calendarsBySource: [String: [CalendarInfo]] = [:]
    private var selectedBySource: [String: [String]] = [:]
    private var syncFailures: [String: CalendarError] = [:]
    private var syncCallsByTrigger: [CalendarSyncTrigger: Int] = [:]
    private var continuations: [AsyncStream<CalendarChange>.Continuation] = []

    private var authChallengesBySource: [String: AuthChallenge] = [:]
    private var connectorHealthBySource: [String: ConnectorHealth] = [:]
    private var settingsSchemaBySource: [String: Data] = [:]
    private var configuredSettingsBySource: [String: Data] = [:]
    private var throwFailures: [CalendarPortThrowingMethod: (source: String?, error: CalendarError)] = [:]
    private var stopCalls = 0

    /// Момент, который фейк ставит в `startedAt` и `finishedAt` каждого `CalendarSyncResult`.
    /// Умолчание — начало эпохи: всякое значение здесь есть вход теста, а не решение фейка,
    /// и реальных часов у фейка нет ни одних (то же правило, что у `ManualClock` в C-018 §4:
    /// момент — значение, а не средство).
    private var syncMoment = Date(timeIntervalSince1970: 0)

    /// - Parameter log: общий журнал вызовов (условие `Н`). Не дали — фейк заводит свой.
    public init(log: PortCallLog = PortCallLog()) {
        self.log = log
    }

    /// Журнал, в который пишет этот фейк. Тот же объект, что передали в инициализатор.
    public var callLog: PortCallLog { log }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    // MARK: - Управление из теста

    /// Задать список источников; порядок сохраняется и отдаётся `listSources()` как есть.
    public func setSources(_ list: [CalendarSourceId]) {
        locked { sources = list }
    }

    /// Задать набор событий на источник. Источник, которого нет в `setSources`, добавляется:
    /// тест, задавший события, всегда получает их и в `sync`, и в `events(from:to:)`.
    public func setEvents(_ list: [MeetingEvent], for source: CalendarSourceId) {
        locked {
            eventsBySource[source.rawValue] = list
            if !sources.contains(where: { $0.rawValue == source.rawValue }) {
                sources.append(source)
            }
        }
    }

    public func setCalendars(_ list: [CalendarInfo], for source: CalendarSourceId) {
        locked { calendarsBySource[source.rawValue] = list }
    }

    /// Заставить `sync` вернуть заданный `CalendarError` для выбранного источника;
    /// `nil` снимает отказ. Отказ одного источника остальных не трогает (инвариант 8 —
    /// обязанность порта; здесь это устройство фейка, а не её проверка).
    public func failSync(with error: CalendarError?, for source: CalendarSourceId) {
        locked { syncFailures[source.rawValue] = error }
    }

    /// Момент, которым заполняются `startedAt` и `finishedAt` результатов `sync`.
    public func setSyncMoment(_ moment: Date) {
        locked { syncMoment = moment }
    }

    /// Протолкнуть изменение в поток. Значение не приводится ни к чему и доходит как есть.
    public func emit(_ change: CalendarChange) {
        let targets = locked { continuations }
        for continuation in targets {
            continuation.yield(change)
        }
    }

    /// Закрыть поток: подписчики досматривают выданное и выходят из цикла.
    public func finishChanges() {
        let targets = locked { () -> [AsyncStream<CalendarChange>.Continuation] in
            let taken = continuations
            continuations = []
            return taken
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    /// Число вызовов `sync` с названным триггером — §«Фейк для тестов» C-005 дословно.
    public func syncCallCount(trigger: CalendarSyncTrigger) -> Int {
        locked { syncCallsByTrigger[trigger] ?? 0 }
    }

    /// Число вызовов `sync` со всеми триггерами разом.
    public var syncCallCount: Int {
        locked { syncCallsByTrigger.values.reduce(0, +) }
    }

    /// Что было в последний раз отдано `setSelectedCalendars(source:calendarIds:)`.
    public func selectedCalendars(for source: CalendarSourceId) -> [String]? {
        locked { selectedBySource[source.rawValue] }
    }

    /// Канонический ответ `beginAuth(source:)` для этого источника. Умолчания нет: без
    /// вызова этого метода `beginAuth` на источнике падает `preconditionFailure`.
    public func setAuthChallenge(_ challenge: AuthChallenge, for source: CalendarSourceId) {
        locked { authChallengesBySource[source.rawValue] = challenge }
    }

    /// Канонический ответ `healthCheck(source:)` для этого источника. Умолчания нет —
    /// тот же довод, что у `setAuthChallenge(_:for:)`.
    public func setConnectorHealth(_ health: ConnectorHealth, for source: CalendarSourceId) {
        locked { connectorHealthBySource[source.rawValue] = health }
    }

    /// Канонический ответ `settingsSchema(source:)` для этого источника. Умолчания нет —
    /// тот же довод, что у `setAuthChallenge(_:for:)`.
    public func setSettingsSchema(_ schema: Data, for source: CalendarSourceId) {
        locked { settingsSchemaBySource[source.rawValue] = schema }
    }

    /// Что в последний раз пришло в `configure(source:settings:)` — та же наблюдаемость,
    /// что `selectedCalendars(for:)` у `setSelectedCalendars`, тем же доводом.
    public func configuredSettings(for source: CalendarSourceId) -> Data? {
        locked { configuredSettingsBySource[source.rawValue] }
    }

    /// Заставить один из пяти бросающих методов вернуть заданную `CalendarError`.
    /// `source == nil` — отказ на всяком источнике; иначе только на названном.
    public func fail(
        with error: CalendarError, on method: CalendarPortThrowingMethod, source: CalendarSourceId? = nil
    ) {
        locked { throwFailures[method] = (source: source?.rawValue, error: error) }
    }

    public func clearFailure(on method: CalendarPortThrowingMethod) {
        locked { throwFailures[method] = nil }
    }

    /// Число вызовов `stop()` — только счётчик, без возможности задать ему ошибку.
    public var stopCallCount: Int {
        locked { stopCalls }
    }

    // MARK: - Оснастка

    private func throwFailureIfAny(_ method: CalendarPortThrowingMethod, source: String) -> CalendarError? {
        locked { () -> CalendarError? in
            guard let failure = throwFailures[method] else { return nil }
            guard let wanted = failure.source else { return failure.error }
            return wanted == source ? failure.error : nil
        }
    }

    // MARK: - CalendarPort

    public func listSources() async -> [CalendarSourceId] {
        log.record(port: Self.portName, method: "listSources()")
        return locked { sources }
    }

    public func listCalendars(source: CalendarSourceId) async throws -> [CalendarInfo] {
        log.record(port: Self.portName, method: "listCalendars(source:)", arguments: [source.rawValue])
        return locked { calendarsBySource[source.rawValue] ?? [] }
    }

    public func setSelectedCalendars(source: CalendarSourceId, calendarIds: [String]) async throws {
        log.record(
            port: Self.portName,
            method: "setSelectedCalendars(source:calendarIds:)",
            arguments: [source.rawValue, calendarIds.joined(separator: ",")]
        )
        locked { selectedBySource[source.rawValue] = calendarIds }
    }

    public func events(from: Date, to: Date) async throws -> [MeetingEvent] {
        log.record(
            port: Self.portName,
            method: "events(from:to:)",
            arguments: [String(from.timeIntervalSince1970), String(to.timeIntervalSince1970)]
        )
        return locked { () -> [MeetingEvent] in
            sources
                .flatMap { eventsBySource[$0.rawValue] ?? [] }
                .filter { from <= $0.start && $0.start < to }
        }
    }

    public func event(id: UUID) async throws -> MeetingEvent? {
        log.record(port: Self.portName, method: "event(id:)", arguments: [id.uuidString])
        return locked { () -> MeetingEvent? in
            sources
                .flatMap { eventsBySource[$0.rawValue] ?? [] }
                .first { $0.id == id }
        }
    }

    public func sync(trigger: CalendarSyncTrigger) async -> [CalendarSyncResult] {
        log.record(port: Self.portName, method: "sync(trigger:)", arguments: [trigger.rawValue])
        return locked { () -> [CalendarSyncResult] in
            syncCallsByTrigger[trigger, default: 0] += 1
            return sources.map { source in
                let failure = syncFailures[source.rawValue]
                let upserted = failure == nil ? (eventsBySource[source.rawValue] ?? []).count : 0
                return CalendarSyncResult(
                    sourceId: source,
                    trigger: trigger,
                    startedAt: syncMoment,
                    finishedAt: syncMoment,
                    upsertedCount: upserted,
                    deletedCount: 0,
                    failure: failure
                )
            }
        }
    }

    public func changes() -> AsyncStream<CalendarChange> {
        log.record(port: Self.portName, method: "changes()")
        return AsyncStream { continuation in
            locked { continuations.append(continuation) }
        }
    }

    public func beginAuth(source: CalendarSourceId) async throws -> AuthChallenge {
        log.record(port: Self.portName, method: "beginAuth(source:)", arguments: [source.rawValue])
        if let error = throwFailureIfAny(.beginAuth, source: source.rawValue) {
            throw error
        }
        guard let challenge = locked({ authChallengesBySource[source.rawValue] }) else {
            preconditionFailure("тест обязан задать AuthChallenge через setAuthChallenge(_:for:) до beginAuth(source:)")
        }
        return challenge
    }

    public func completeAuth(source: CalendarSourceId, callbackUrl: URL) async throws -> String? {
        log.record(
            port: Self.portName, method: "completeAuth(source:callbackUrl:)",
            arguments: [source.rawValue, callbackUrl.absoluteString]
        )
        if let error = throwFailureIfAny(.completeAuth, source: source.rawValue) {
            throw error
        }
        // Контракт не даёт тесту канонического значения на этот ответ (в отличие от
        // beginAuth/healthCheck/settingsSchema) — только отказ. `nil` — единственный
        // ответ, не требующий входа теста.
        return nil
    }

    public func settingsSchema(source: CalendarSourceId) async throws -> Data {
        log.record(port: Self.portName, method: "settingsSchema(source:)", arguments: [source.rawValue])
        if let error = throwFailureIfAny(.settingsSchema, source: source.rawValue) {
            throw error
        }
        guard let schema = locked({ settingsSchemaBySource[source.rawValue] }) else {
            preconditionFailure("тест обязан задать схему через setSettingsSchema(_:for:) до settingsSchema(source:)")
        }
        return schema
    }

    public func configure(source: CalendarSourceId, settings: Data) async throws {
        log.record(
            port: Self.portName, method: "configure(source:settings:)",
            arguments: [source.rawValue, String(decoding: settings, as: UTF8.self)]
        )
        if let error = throwFailureIfAny(.configure, source: source.rawValue) {
            throw error
        }
        locked { configuredSettingsBySource[source.rawValue] = settings }
    }

    public func healthCheck(source: CalendarSourceId) async throws -> ConnectorHealth {
        log.record(port: Self.portName, method: "healthCheck(source:)", arguments: [source.rawValue])
        if let error = throwFailureIfAny(.healthCheck, source: source.rawValue) {
            throw error
        }
        guard let health = locked({ connectorHealthBySource[source.rawValue] }) else {
            preconditionFailure("тест обязан задать ConnectorHealth через setConnectorHealth(_:for:) до healthCheck")
        }
        return health
    }

    public func stop() async {
        log.record(port: Self.portName, method: "stop()")
        locked { stopCalls += 1 }
    }
}
