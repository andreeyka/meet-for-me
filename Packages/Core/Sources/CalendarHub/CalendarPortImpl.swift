//  CalendarPortImpl — реализация CalendarPort (C-005 v8) и хост-роль для CalendarConnector
//  (C-006 v12), путь in-process. Перечень приёмки — MEE-347, план проверки — MEE-361.
//
//  Модуль: calendar-hub · Владелец: DEV-1 · Слой: домен
//
//  Часть 1 (#85) реализовала весь код перечисленных ниже групп; тесты на бо́льшую часть
//  этого списка написаны только частью 2 (MEE-362 ч.2) — какие именно тесты и где, называет
//  шапка каждого файла `CalendarHubTests` по отдельности, эта шапка счёт не дублирует и не
//  держит (возврат РП, приёмка #85, дефект 6: этот абзац раньше утверждал «группы Б, В, Г,
//  Д, Е закрыты», хотя тестов на них не было ни строки — вводило в заблуждение).
//
//  Группы А (К1-К10, кроме версии MAJOR у К1 и кадра shutdown у К9-Б — обе части нужны
//  только stdio-транспорту, ещё не написанному, group Ж), Б (К11-К14, К61), В (К15-К29,
//  дедуп/слияние — К20-К24/К28 только в пределах одной синхронизации, межсинхронизационное
//  слияние ждёт IR-126/MEE-372), Г (К30-К43, синхронизация), Д (К62-К63, поток changes),
//  Е (К44-К45, расписание). Управляющая поверхность источника (шесть методов MEE-355,
//  v6/IR-120 — beginAuth/completeAuth/settingsSchema/configure/healthCheck/stop; группы
//  К/Л, К3 вход Б/К66-К69/К71-К75).

import Foundation
import DomainCore

public actor CalendarPortImpl: CalendarPort {

    // Не `private`: `connectorRepository`/`meetingRepository`/`waitSeam`/`connectors`/
    // `capabilities`/`inFlightSync`/`emit(_:)` читают и CalendarPortImplSync.swift, и
    // CalendarPortImplCallWrapper.swift — `private` в Swift видна только внутри своего
    // ФАЙЛА, а актор теперь один тип на три файла (тот же приём, что у
    // `AudioCaptureImpl`/`capture`). Наружу модуля ничего из этого не течёт — доступ по
    // умолчанию (`internal`), не `public`.
    let connectorRepository: ConnectorRepository
    let meetingRepository: MeetingRepository
    let waitSeam: WaitSeam
    private let secretStore: SecretStore
    let connectors: [CalendarSourceId: CalendarConnector]

    var capabilities: [CalendarSourceId: ConnectorCapabilities] = [:]
    private var logEntries: [CalendarSourceId: [(level: LogLevel, message: String)]] = [:]
    private var notifyEntries: [CalendarSourceId: [(kind: HostNotificationKind, detail: String?)]] = [:]
    var inFlightSync: [CalendarSourceId: Task<CalendarSyncResult, Never>] = [:]
    private let changeHub = CalendarChangeHub()
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

    /// `nonisolated`: C-005 «Определение» объявляет `changes()` НЕ `async` — актор-изолированная
    /// реализация этой подписи не удовлетворяет протокольное требование (см. `CalendarChangeHub.swift`
    /// — тот же приём, что `SessionChangeHub`, DomainCore/C-018). Хаб живёт под своим замком,
    /// снимка при подписке нет (К62 прямо это запрещает, в отличие от инв. 21 C-018).
    public nonisolated func changes() -> AsyncStream<CalendarChange> {
        changeHub.subscribe()
    }

    func emit(_ change: CalendarChange) {
        changeHub.publish(change)
    }

    // MARK: - CalendarPort — синхронизация (К30-К39, К42-К43, К71-К72)
    //
    // sync(trigger:), syncOne(source:trigger:), дедуп и применение payload'ов —
    // CalendarPortImplSync.swift (вынесено отдельным файлом, SwiftLint file_length/
    // type_body_length считают каждое расширение типа отдельно).

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
        // СТРОКА (возврат РП, приёмка #85, дефект 3 — временно откачено): shutdown() без
        // таймаута может повесить stop() навсегда на зависшем коннекторе — намеченный фикс
        // (callConnector(..., retryable: false) { await connector.shutdown() }) скомпилировался,
        // но прогон CI после него завис на ОБЕИХ платформах (Linux и macOS, 300с/360с) без
        // единой строки диагностики — обёртчик CI пишет вывод swift test в файл и печатает
        // его только при обычном завершении, не при принудительном убийстве по таймауту,
        // так что причина зависания не видна ни через один доступный мне канал лога.
        // Отката к простому вызову достаточно, чтобы ЭТУ правку (тесты MEE-362 ч.2) сдать
        // зелёной; сам дефект 3 остаётся открытым — беру его отдельным заходом, с локальной
        // гонкой таймаута вместо `callConnector` целиком (тот тянет ещё и повтор §5.2, шутдауну
        // ненужный), проверенным малым прогоном ДО того, как он попадёт в этот PR снова.
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
    ///
    /// СТРОКА (возврат РП, приёмка #85, дефект 2 — временно откачено): актор реентерабелен
    /// через `await` внутри — два одновременных вызова, заставших `capabilities[source] ==
    /// nil` до первого `await`, оба звали бы `connector.initialize()`, нарушая К1/К7.
    /// Намеченный фикс (`inFlightInitialize`, отдельный `Task` на источник, тот же приём, что
    /// `inFlightSync` у `syncOne`) скомпилировался, но прогон CI после него завис на ОБЕИХ
    /// платформах без единой строки диагностики дальше «Build complete!» — тот же симптом,
    /// что и у отката дефекта 3 рядом, и revert одного дефекта 3 его не снял (бисекция,
    /// комментарий MEE-362). Проверяю здесь: может статься, лишний `Task` на КАЖДЫЙ вызов
    /// `ensureInitialized` (а он один на почти каждый тест) исчерпывает кооперативный пул
    /// потоков раннера CI, а не гонка сама по себе. Дефект 2 остаётся открытым; следующий
    /// заход — без отдельного `Task`, тем же приёмом continuation-очереди, что уже стоит у
    /// `hangOrGate`/`FakeWaitSeam.sleep`, без нового потока пула на каждый вызов.
    func ensureInitialized(_ source: CalendarSourceId, connector: CalendarConnector) async throws {
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

    func requireRecord(_ source: CalendarSourceId) async throws -> ConnectorRecord {
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
    //
    // MethodTimeout, callConnector(source:connector:timeout:retryable:operation:), raceTimeout,
    // mapConnectorError — CalendarPortImplCallWrapper.swift (тот же довод, что у Sync.swift).
}
