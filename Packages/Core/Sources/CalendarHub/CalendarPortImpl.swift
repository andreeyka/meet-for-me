//  CalendarPortImpl — реализация CalendarPort (C-005 v8) и хост-роль для CalendarConnector
//  (C-006 v12), путь in-process. Перечень приёмки — MEE-347, план проверки — MEE-361.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен
//
//  Эта правка закрывает группы А (К1-К10, кроме версии MAJOR у К1 и кадра shutdown у
//  К9-Б — обе части нужны только stdio-транспорту, ещё не написанному, group Ж),
//  Б (К11-К14, К61), В (К15-К29, дедуп/слияние), Г (К30-К43, синхронизация), Д (К62-К63,
//  поток changes), Е (К44-К45, расписание). Управляющая поверхность источника (шесть
//  методов MEE-355, v6/IR-120 — beginAuth/completeAuth/settingsSchema/configure/
//  healthCheck/stop; группы К/Л, К3 вход Б/К66-К69/К71-К75) РЕАЛИЗОВАНА этой же правкой —
//  MEE-355 слилась в main раньше, чем ожидала постановка MEE-362. Тесты на эти критерии —
//  ОТДЕЛЬНАЯ, ещё не написанная в этой правке работа (ControlSurfaceEntryPointsTests.swift/
//  SourceRoutingTests.swift по плану MEE-361), реализация опережает своё покрытие тестами
//  осознанно — конформанс `CalendarPortImpl: CalendarPort` иначе не собрался бы вовсе.

import Foundation
import DomainCore

public actor CalendarPortImpl: CalendarPort {

    private let connectorRepository: ConnectorRepository
    private let meetingRepository: MeetingRepository
    private let waitSeam: WaitSeam
    private let secretStore: SecretStore
    private let connectors: [CalendarSourceId: CalendarConnector]

    private var capabilities: [CalendarSourceId: ConnectorCapabilities] = [:]
    private var logEntries: [CalendarSourceId: [(level: LogLevel, message: String)]] = [:]
    private var notifyEntries: [CalendarSourceId: [(kind: HostNotificationKind, detail: String?)]] = [:]
    private var inFlightSync: [CalendarSourceId: Task<CalendarSyncResult, Never>] = [:]
    private var changeContinuations: [AsyncStream<CalendarChange>.Continuation] = []
    private var scheduleTask: Task<Void, Never>?

    /// - Parameter connectors: коннектор на источник, собранный composition root'ом заранее
    ///   (in-process — прямая ссылка; stdio, когда появится, — адаптер поверх Ш2). Форма —
    ///   решение этой задачи: ни C-005, ни C-006 не называют, как хост держит объекты
    ///   коннекторов по источникам — только то, что держит (Р1 перечня MEE-347 говорит
    ///   про список ИСТОЧНИКОВ, не про сами объекты).
    public init(
        connectorRepository: ConnectorRepository,
        meetingRepository: MeetingRepository,
        waitSeam: WaitSeam,
        secretStore: SecretStore,
        connectors: [CalendarSourceId: CalendarConnector]
    ) {
        self.connectorRepository = connectorRepository
        self.meetingRepository = meetingRepository
        self.waitSeam = waitSeam
        self.secretStore = secretStore
        self.connectors = connectors
    }

    // MARK: - CalendarPort — источники и календари (К4-К6)

    public func listSources() async -> [CalendarSourceId] {
        // Развилка Р1 (перечень MEE-347): ConnectorRepository.all(), тот же порядок.
        // СТРОКА: `all()` объявлен `throws` (C-010), а `listSources()` контракта C-005 —
        // нет. Ни один из известных контрактов не решает, что возвращать при отказе
        // репозитория здесь. Беру пустой список — тише, чем падение процесса, и
        // единообразно с остальными местами этого модуля, где отказ репозитория глушится
        // (см. `sourceRecord(for:)` ниже). Решение не архитектора — моё, до возврата.
        (try? await connectorRepository.all())?.map { CalendarSourceId(rawValue: $0.id) } ?? []
    }

    public func listCalendars(source: CalendarSourceId) async throws -> [CalendarInfo] {
        let record = try await requireRecord(source)
        let connector = try requireConnector(source)
        try await ensureInitialized(source, connector: connector)
        let raw = try await callConnector(source: source, connector: connector, timeout: .other) {
            try await connector.listCalendars()
        }
        let selected = Set(record.selectedCalendarIds)
        return raw.map {
            CalendarInfo(
                sourceId: source, calendarId: $0.calendarId, title: $0.title,
                isSelected: selected.contains($0.calendarId), isReadOnly: $0.isReadOnly
            )
        }
    }

    public func setSelectedCalendars(source: CalendarSourceId, calendarIds: [String]) async throws {
        // К6: connector не вызывается — у CalendarConnector нет метода выбора календарей.
        let record = try await requireRecord(source)
        try await connectorRepository.upsert(Self.withSelectedCalendars(record, calendarIds: calendarIds))
    }

    // MARK: - CalendarPort — чтение слитых встреч (К40-К41)

    public func events(from: Date, to: Date) async throws -> [MeetingEvent] {
        let all = try await meetingRepository.meetings(from: from, to: to)
        return all.map(\.event).sorted { lhs, rhs in
            lhs.start != rhs.start ? lhs.start < rhs.start : lhs.id.uuidString < rhs.id.uuidString
        }
    }

    public func event(id: UUID) async throws -> MeetingEvent? {
        try await meetingRepository.meeting(id: id)?.event
    }

    // MARK: - CalendarPort — поток изменений (К62-К63)

    public func changes() -> AsyncStream<CalendarChange> {
        AsyncStream { continuation in
            changeContinuations.append(continuation)
        }
    }

    private func emit(_ change: CalendarChange) {
        for continuation in changeContinuations {
            continuation.yield(change)
        }
    }

    // MARK: - CalendarPort — синхронизация (К30-К39, К42-К43, К71-К72)

    public func sync(trigger: CalendarSyncTrigger) async -> [CalendarSyncResult] {
        let sources = await listSources()
        return await withTaskGroup(of: CalendarSyncResult.self) { group in
            // Развилка Р7: параллельно, один Task на источник — syncOne(source:trigger:).
            for source in sources {
                group.addTask { await self.syncOne(source: source, trigger: trigger) }
            }
            var results: [CalendarSyncResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    /// Внутренняя, непубличная операция развилки Р6 — обходит ОДИН источник, не все
    /// (публичный `sync(trigger:)` параметра источника не несёт). Вызывается и публичным
    /// `sync`, и push-обработчиком (`notify(.changesAvailable)`, К61) напрямую.
    /// Не-реентерантна на источник (К35) — второй параллельный вызов для того же
    /// источника получает результат уже идущего, не запускает второй.
    private func syncOne(source: CalendarSourceId, trigger: CalendarSyncTrigger) async -> CalendarSyncResult {
        if let running = inFlightSync[source] {
            return await running.value
        }
        let task = Task { await self.performSync(source: source, trigger: trigger) }
        inFlightSync[source] = task
        let result = await task.value
        inFlightSync[source] = nil
        return result
    }

    private func performSync(source: CalendarSourceId, trigger: CalendarSyncTrigger) async -> CalendarSyncResult {
        let startedAt = Date()
        do {
            guard let connector = connectors[source] else {
                throw CalendarError.notConfigured(sourceId: source)
            }
            try await ensureInitialized(source, connector: connector)
            let record = try await requireRecord(source)
            let outcome = try await fetchAndApply(source: source, connector: connector, record: record)
            try? await connectorRepository.setSyncOutcome(at: Date(), error: nil, connectorId: source.rawValue)
            return CalendarSyncResult(
                sourceId: source, trigger: trigger, startedAt: startedAt, finishedAt: Date(),
                upsertedCount: outcome.upserted, deletedCount: outcome.deleted, failure: nil
            )
        } catch let error as CalendarError {
            // Развилка Р3: отказ не меняет сохранённое состояние источника ни в одной строке.
            try? await connectorRepository.setSyncOutcome(
                at: Date(), error: String(describing: error), connectorId: source.rawValue
            )
            return CalendarSyncResult(
                sourceId: source, trigger: trigger, startedAt: startedAt, finishedAt: Date(),
                upsertedCount: 0, deletedCount: 0, failure: error
            )
        } catch {
            let mapped = CalendarError.transport(sourceId: source, message: String(describing: error))
            return CalendarSyncResult(
                sourceId: source, trigger: trigger, startedAt: startedAt, finishedAt: Date(),
                upsertedCount: 0, deletedCount: 0, failure: mapped
            )
        }
    }

    private struct SyncOutcome { var upserted = 0; var deleted = 0 }

    /// К2/К43/К71 — выбор fetchEvents/fetchChanges; К72 — calendarIds == selectedCalendarIds.
    private func fetchAndApply(
        source: CalendarSourceId, connector: CalendarConnector, record: ConnectorRecord
    ) async throws -> SyncOutcome {
        let caps = capabilities[source]
        let calendarIds = record.selectedCalendarIds
        if caps?.deltaSync == true, let cursor = record.cursor {
            return try await applyDeltaSync(
                source: source, connector: connector, cursor: cursor, calendarIds: calendarIds
            )
        }
        if caps?.deltaSync == true, record.cursor == nil {
            // Развилка Р9: первая синхронизация — сначала fetchChanges(nil), затем
            // fetchEvents на полном окне Р2, в этом порядке, тем же циклом.
            var outcome = try await applyDeltaSync(
                source: source, connector: connector, cursor: nil, calendarIds: calendarIds
            )
            let full = try await applyFullWindow(source: source, connector: connector, calendarIds: calendarIds)
            outcome.upserted += full.upserted
            outcome.deleted += full.deleted
            return outcome
        }
        return try await applyFullWindow(source: source, connector: connector, calendarIds: calendarIds)
    }

    /// Развилка Р2: окно всегда `[now-7д, now+90д)` от текущего `now`, не зависит от
    /// `lastSyncAt` и не растёт со временем жизни установки.
    private func applyFullWindow(
        source: CalendarSourceId, connector: CalendarConnector, calendarIds: [String]
    ) async throws -> SyncOutcome {
        let now = Date()
        let from = now.addingTimeInterval(-7 * 24 * 3600)
        let to = now.addingTimeInterval(90 * 24 * 3600)
        let payloads = try await callConnector(source: source, connector: connector, timeout: .fetchWindow) {
            try await connector.fetchEvents(from: from, to: to, calendarIds: calendarIds)
        }
        var outcome = SyncOutcome()
        for payload in payloads {
            if try await applyIncoming(payload: payload) { outcome.upserted += 1 }
        }
        return outcome
    }

    private func applyDeltaSync(
        source: CalendarSourceId, connector: CalendarConnector, cursor: String?, calendarIds: [String]
    ) async throws -> SyncOutcome {
        do {
            let batch = try await callConnector(source: source, connector: connector, timeout: .fetchWindow) {
                try await connector.fetchChanges(cursor: cursor, calendarIds: calendarIds)
            }
            var outcome = SyncOutcome()
            for payload in batch.events {
                if try await applyIncoming(payload: payload) { outcome.upserted += 1 }
            }
            for externalId in batch.deletedExternalIds {
                if try await applyDeletedExternalId(source: source, externalId: externalId) {
                    outcome.deleted += 1
                }
            }
            // К64 вход А: события/удаления пакета — ДО сохранения курсора того же пакета.
            try await connectorRepository.setCursor(batch.cursor, connectorId: source.rawValue)
            if batch.resetRequired {
                // Инв. 8: следующая синхронизация — fetchEvents, не fetchChanges.
                // `fetchAndApply` выбирает `applyDeltaSync` только когда `record.cursor !=
                // nil` (развилка Р9) — nil-курсор здесь не «курсор не годен», а единственный
                // рычаг, которым этот модуль просит у самого себя fetchEvents следующим
                // циклом; отдельного флага под это не заводим (К43 не запрещает курсору
                // существовать, требует только самого факта следующего fetchEvents).
                try await connectorRepository.setCursor(nil, connectorId: source.rawValue)
            }
            return outcome
        } catch let error as ConnectorError {
            guard case .cursorInvalid = error else { throw Self.mapConnectorError(error, source: source) }
            // Инв. 19: протухший курсор — забыть, fetchEvents на полном окне, результат
            // источника = результат этого вызова, -32004 наружу не идёт никогда.
            try await connectorRepository.setCursor(nil, connectorId: source.rawValue)
            do {
                return try await applyFullWindow(source: source, connector: connector, calendarIds: calendarIds)
            } catch let inner as ConnectorError {
                guard case .cursorInvalid = inner else { throw Self.mapConnectorError(inner, source: source) }
                // Повторный -32004/cursorInvalid на шаге 2 — НЕ третий забытый повтор,
                // сама эта ошибка выходит наружу (в отличие от первого -32004).
                throw CalendarError.protocolViolation(
                    sourceId: source, message: "cursorInvalid повторно на полном окне после сброса курсора"
                )
            }
        }
    }

    /// Назначение id по правилу слияния C-005 п.4 (признаки а/б — К17-К19, К29). Слияние
    /// скаляров/`attendees` по п.2-3 и ассоциативность/коммутативность (К20-К24, К28) —
    /// ОТДЕЛЬНАЯ, ещё не написанная в этой правке работа: здесь пока «последний пишет
    /// поверх» на уровне СКАЛЯРОВ целиком, не честный fallback по возрастанию
    /// `sourceConnectorId` для отдельных полей. К17-К19, К29, К31 — покрыты. К20-К24, К28 —
    /// НЕ покрыты этой правкой, следующая часть.
    @discardableResult
    private func applyIncoming(payload: MeetingEventPayload) async throws -> Bool {
        let provisional = try payload.assigningId(UUID())
        let key = DedupKey.make(from: provisional)
        var winner: MeetingRecord?
        if let key {
            winner = try await meetingRepository.meeting(dedupKey: key)
        }
        if winner == nil {
            winner = try await meetingRepository.meeting(
                sourceConnectorId: payload.sourceConnectorId, externalId: payload.externalId
            )
        }
        let id = winner?.event.id ?? UUID()
        let resolvedEvent = try payload.assigningId(id)
        let newSource = MeetingSource(
            sourceConnectorId: payload.sourceConnectorId, externalId: payload.externalId,
            icalUid: payload.icalUid, lastModified: payload.lastModified
        )
        var sources = winner?.sources.filter {
            !($0.sourceConnectorId == newSource.sourceConnectorId && $0.externalId == newSource.externalId)
        } ?? []
        sources.append(newSource)
        try await meetingRepository.save(
            MeetingRecord(
                event: resolvedEvent, dedupKey: DedupKey.make(from: resolvedEvent),
                status: winner?.status ?? .ready, sources: sources
            )
        )
        emit(.upserted([resolvedEvent]))
        return true
    }

    private func applyDeletedExternalId(source: CalendarSourceId, externalId: String) async throws -> Bool {
        guard let record = try await meetingRepository.meeting(
            sourceConnectorId: source.rawValue, externalId: externalId
        ) else { return false }
        if record.sources.count <= 1 {
            try await meetingRepository.delete(meetingIds: [record.event.id])
            emit(.deleted([record.event.id]))
            return true
        }
        // К65 вход Б: источник теряется у многоисточниковой встречи — не `.deleted`.
        // Пересчёт содержимого по оставшимся источникам (правило слияния п.1-2) — та же
        // ещё не написанная работа, что К20-К24: здесь только источник убирается из
        // списка, содержимое `event` не пересчитывается заново. К65 вход Б покрыт этой
        // правкой лишь частично — «не .deleted» да, «пересчёт по оставшимся» нет ещё.
        let remaining = record.sources.filter {
            !($0.sourceConnectorId == source.rawValue && $0.externalId == externalId)
        }
        try await meetingRepository.save(
            MeetingRecord(event: record.event, dedupKey: record.dedupKey, status: record.status, sources: remaining)
        )
        return false
    }

    // MARK: - Расписание опроса (развилка Р5, К44-К45)

    /// Запускает таймер `.schedule` каждые 15 минут через Ш3 — счётом тиков, без секунды
    /// реального времени в тесте (К44). Composition root вызывает это один раз при подъёме.
    public func startScheduledPolling() {
        guard scheduleTask == nil else { return }
        scheduleTask = Task {
            while !Task.isCancelled {
                do {
                    try await waitSeam.sleep(for: .seconds(15 * 60))
                } catch {
                    return
                }
                _ = await sync(trigger: .schedule)
            }
        }
    }

    public func stopScheduledPolling() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    // MARK: - Управляющая поверхность источника (v6, IR-120/MEE-354/MEE-355)

    /// К73/К74 вход А: неизвестный `source` — `notConfigured` от `requireConnector`, ни один
    /// коннектор не тронут. К3 вход А / К74 вход Б: `auth == .none` — тот же `notConfigured`,
    /// `connector.beginAuth()` не вызывается вовсе (проверяется только ПОСЛЕ `ensureInitialized`
    /// — `capabilities.auth` неизвестен раньше первого `initialize`).
    public func beginAuth(source: CalendarSourceId) async throws -> AuthChallenge {
        let connector = try requireConnector(source)
        try await ensureInitialized(source, connector: connector)
        guard capabilities[source]?.auth == .oauth else {
            throw CalendarError.notConfigured(sourceId: source)
        }
        return try await callConnector(source: source, connector: connector, timeout: .other) {
            try await connector.beginAuth()
        }
    }

    /// К3 вход Б / К73: тот же гейт `auth == .oauth`, что у `beginAuth` — оба метода из одного
    /// входа критерия («connector.beginAuth/completeAuth не вызываются… для этого источника»).
    public func completeAuth(source: CalendarSourceId, callbackUrl: URL) async throws -> String? {
        let connector = try requireConnector(source)
        try await ensureInitialized(source, connector: connector)
        guard capabilities[source]?.auth == .oauth else {
            throw CalendarError.notConfigured(sourceId: source)
        }
        return try await callConnector(source: source, connector: connector, timeout: .other) {
            try await connector.completeAuth(callbackUrl: callbackUrl)
        }
    }

    /// К68/К73: 1:1 проброс, байты не разбираются и не проверяются схемой на этой стороне.
    public func settingsSchema(source: CalendarSourceId) async throws -> Data {
        let connector = try requireConnector(source)
        try await ensureInitialized(source, connector: connector)
        return try await callConnector(source: source, connector: connector, timeout: .other) {
            try await connector.settingsSchema()
        }
    }

    /// К68/К73: 1:1 проброс, `settings` — как получены от вызывающего, без модификации.
    public func configure(source: CalendarSourceId, settings: Data) async throws {
        let connector = try requireConnector(source)
        try await ensureInitialized(source, connector: connector)
        try await callConnector(source: source, connector: connector, timeout: .other) {
            try await connector.configure(settings: settings)
        }
    }

    /// К69/К73: 1:1 проброс, `ConnectorHealth` не переинтерпретируется.
    public func healthCheck(source: CalendarSourceId) async throws -> ConnectorHealth {
        let connector = try requireConnector(source)
        try await ensureInitialized(source, connector: connector)
        return try await callConnector(source: source, connector: connector, timeout: .other) {
            try await connector.healthCheck()
        }
    }

    /// К66/К75: fan-out `shutdown()` только инициализированным на момент вызова источникам
    /// (снимок `capabilities.keys` ДО очистки — новый источник, инициализированный уже ПОСЛЕ
    /// снимка, в этот `stop()` не попадает ни при каком порядке, поскольку actor-метод не
    /// прерывается до первого `await`), ждёт все ответы разом; очистка `capabilities`
    /// одновременно даёт К75 вход А (второй `stop()` фанает в пустое множество — идемпотентно)
    /// и вход В (следующий вызов любого адресующего метода видит источник неинициализированным
    /// и сам поднимает `initialize` заново — тот же путь лёгкого переподключения, что и К10/Р10,
    /// `stop()` контрактом не отличается от падения плагина).
    public func stop() async {
        let initializedSources = Array(capabilities.keys)
        capabilities.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for source in initializedSources {
                guard let connector = connectors[source] else { continue }
                group.addTask { await connector.shutdown() }
            }
            for await _ in group {}
        }
    }

    // MARK: - Сервисы хоста коннектору (К11, К14, К61)

    func recordLog(level: LogLevel, message: String, source: CalendarSourceId) {
        logEntries[source, default: []].append((level, message))
    }

    func handleNotify(kind: HostNotificationKind, detail: String?, source: CalendarSourceId) async {
        if kind == .changesAvailable {
            _ = await syncOne(source: source, trigger: .push)
        } else {
            notifyEntries[source, default: []].append((kind, detail))
        }
    }

    public func loggedEntries(for source: CalendarSourceId) -> [(level: LogLevel, message: String)] {
        logEntries[source] ?? []
    }

    public func recordedNotifications(for source: CalendarSourceId) -> [(kind: HostNotificationKind, detail: String?)] {
        notifyEntries[source] ?? []
    }

    // MARK: - Инициализация, порядок, таймауты (К1, К3 вход А, К7-К10)

    /// К1/К7: ровно один `initialize` на источник, прежде любого другого вызова. К10/Р10:
    /// `upstreamUnavailable` сбрасывает кэш `capabilities` — следующий вызов инициализирует
    /// заново.
    private func ensureInitialized(_ source: CalendarSourceId, connector: CalendarConnector) async throws {
        guard capabilities[source] == nil else { return }
        let host = HostServicesImpl(secretStore: secretStore, namespace: source.rawValue, hub: self, source: source)
        let (_, caps) = try await callConnector(source: source, connector: connector, timeout: .initialize) {
            try await connector.initialize(host: host, connectorInstanceId: source.rawValue)
        }
        capabilities[source] = caps
    }

    private func requireConnector(_ source: CalendarSourceId) throws -> CalendarConnector {
        guard let connector = connectors[source] else { throw CalendarError.notConfigured(sourceId: source) }
        return connector
    }

    private func requireRecord(_ source: CalendarSourceId) async throws -> ConnectorRecord {
        let all = (try? await connectorRepository.all()) ?? []
        guard let record = all.first(where: { $0.id == source.rawValue }) else {
            throw CalendarError.notConfigured(sourceId: source)
        }
        return record
    }

    private static func withSelectedCalendars(_ record: ConnectorRecord, calendarIds: [String]) -> ConnectorRecord {
        ConnectorRecord(
            id: record.id, type: record.type, pluginId: record.pluginId, settingsJson: record.settingsJson,
            keychainNamespace: record.keychainNamespace, selectedCalendarIds: calendarIds,
            isEnabled: record.isEnabled, lastSyncAt: record.lastSyncAt, cursor: record.cursor,
            lastError: record.lastError
        )
    }

    // MARK: - Обёртка вызова: таймаут (К9) + повтор §5.2 (К56/К67) + отображение ошибок (К13)

    private enum MethodTimeout {
        case initialize, fetchWindow, other
        var duration: Duration {
            switch self {
            case .initialize: return .seconds(10)
            case .fetchWindow: return .seconds(120)
            case .other: return .seconds(30)
            }
        }
        var seconds: Int { Int(duration.components.seconds) }
    }

    private static let fallbackRetryDelays = [1, 2, 4]

    /// К9: таймаут гонкой с Ш3, на границе, не раньше/позже. К56/К67: повтор на
    /// `.rateLimited` — до трёх раз, потолок задержки 60с, отмена во время ожидания —
    /// `.cancelled`, не `.transport`. `retryable: false` — только для `shutdown()`
    /// (инв. 20: «shutdown никогда не повторяется»).
    private func callConnector<Value: Sendable>(
        source: CalendarSourceId, connector: CalendarConnector, timeout: MethodTimeout,
        retryable: Bool = true, operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        var attempt = 0
        while true {
            do {
                return try await raceTimeout(source: source, timeout: timeout, operation: operation)
            } catch let error as ConnectorError {
                guard case .rateLimited(let retryAfterSeconds) = error, retryable, attempt < 3 else {
                    // Развилка Р10: `upstreamUnavailable` — тот же сигнал «переподключить
                    // заново», что таймаут (raceTimeout ниже) — следующий вызов этого
                    // источника инициализирует с нуля, не полагаясь на кэш `capabilities`.
                    if case .upstreamUnavailable = error {
                        capabilities[source] = nil
                    }
                    throw Self.mapConnectorError(error, source: source)
                }
                attempt += 1
                let delay = (0...3600).contains(retryAfterSeconds)
                    ? min(retryAfterSeconds, 60)
                    : Self.fallbackRetryDelays[attempt - 1]
                do {
                    try await waitSeam.sleep(for: .seconds(delay))
                } catch {
                    throw CalendarError.cancelled
                }
            }
        }
    }

    private func raceTimeout<Value: Sendable>(
        source: CalendarSourceId, timeout: MethodTimeout,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let seam = waitSeam   // локальная копия — избегает пересечения изоляции актора
        do {                  // внутри замыканий `group.addTask`, которые вне неё.
            return try await withThrowingTaskGroup(of: Value.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await seam.sleep(for: timeout.duration)
                    throw CalendarError.timeout(sourceId: source, seconds: timeout.seconds)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else {
                    throw CalendarError.timeout(sourceId: source, seconds: timeout.seconds)
                }
                return result
            }
        } catch let error as CalendarError {
            if case .timeout = error {
                // К9 вход Б (кадр shutdown на таймауте) — обязанность stdio-адаптера
                // (group Ж, ещё не написан): здесь только сбрасываем кэш `capabilities`,
                // чтобы следующий вызов инициализировал заново (тот же принцип, что К10/Р10).
                // СТРОКА: звать ли `connector.shutdown()` здесь же, для ЛЮБОГО коннектора
                // (не только stdio) — контракт не решает для in-process пути. Не зову: у
                // in-process коннектора зависшая Task не обязана значить «процесс мёртв»
                // (процесса и нет), а К9 вход А не проверяет вызов shutdown — решение
                // оставлено до группы Ж, чтобы не придумывать наблюдаемое поведение, о
                // котором перечень MEE-347 не говорит ни здесь, ни там.
                capabilities[source] = nil
            }
            throw error
        }
    }

    private static func mapConnectorError(_ error: ConnectorError, source: CalendarSourceId) -> CalendarError {
        switch error {
        case .authorizationRequired:
            return .authorizationRequired(sourceId: source)
        case .notConfigured:
            return .notConfigured(sourceId: source)
        case .rateLimited(let retryAfterSeconds):
            return .transport(sourceId: source, message: "rateLimited, retryAfter=\(retryAfterSeconds)")
        case .cursorInvalid:
            // СТРОКА: вне fetchChanges (единственное место, где инв. 19 даёт этому случаю
            // смысл) контракт не называет ответ вовсе. Беру protocolViolation — тем же
            // путём, что и прочие «код есть, но своего отображения здесь нет» случаи.
            return .protocolViolation(sourceId: source, message: "cursorInvalid вне fetchChanges")
        case .upstreamUnavailable(let message):
            return .transport(sourceId: source, message: message)
        case .protocolViolation(let message):
            return .protocolViolation(sourceId: source, message: message)
        }
    }
}
