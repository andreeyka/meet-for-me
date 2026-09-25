//  AppFacadeImpl — реализация `AppFacade` (C-016 v9, MEE-25) поверх настоящих портов и
//  репозиториев. MEE-420 часть 2 (план MEE-410), первый срез: группы А (К4) и Б (К5–К9)
//  реализованы и покрыты тестами; несколько мелких, дословно однозначных сквозных обёрток
//  (§«Поведение»: «фасад — тонкий слой сборки… вызывает порты и репозитории») реализованы
//  вместе с ними, потому что риск ошибки в них тот же, что у уже проверенных методов, —
//  их приёмка в этом PR не заявляется, тесты для них заводит соответствующая группа плана.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧТО НЕ РЕАЛИЗОВАНО ЭТИМ PR, И ПОЧЕМУ ЭТО НЕ НЕДОДЕЛКА. Оставшиеся ~26 методов
//  протокола (группы В–Ц плана, кроме уже названных сквозных обёрток) бросают
//  `notImplemented(_:)` — самоописывающийся отказ, а не молчаливая заглушка: вызвать их
//  сегодня физически некому — `App/` (композиционный корень, единственное место, что
//  создаёт `AppFacadeImpl`) не существует ни одним файлом (план MEE-410 §7, слой 3), и до
//  его появления эти методы мертвы для продакшена, а не только для тестов. Реализация
//  каждой группы — предмет своего PR, по прямому разрешению постановки МЕЕ-420
//  («можно разбить фасад на несколько PR по группам плана»).
//
//  `status()` — минимальная, честно неполная реализация: `activeSession`/`connectors`
//  оставлены пустыми (группы Р/О ещё не реализованы), `permissionsReady` — консервативное
//  `.notReady` (не вычисляется без `AppSettings`, которую `settings()` пока не умеет
//  читать — см. ниже), `upcoming`/счётчики задач — нули/пусто до групп Н/К. Ни одно поле
//  не изобретает данных, которых порты не дали.
//
//  `settings()`/`updateSettings` НЕ реализованы вовсе (бросают `notImplemented`), а не
//  частично: `AppSettings.slice1Defaults` не объявлен (находка MEE-289, сообщена
//  архитектору в `AppSettings.swift`, актуальна и здесь) — семь из двенадцати полей не
//  имеют значения по умолчанию, названного текстом контракта. `settings()` без строки в
//  `SettingsRepository` обязан вернуть эти умолчания (§2.1); подставить их самостоятельно
//  значило бы изобрести продуктовое решение, которого контракт не называет. Ждёт ответа
//  архитектора, тем же приёмом, что и весь этот пробел с момента MEE-289.

import Foundation

public actor AppFacadeImpl: AppFacade {

    let meetingRepository: MeetingRepository
    let recordings: RecordingRepository
    let transcripts: TranscriptRepository
    let persons: PersonRepository
    let permissionsPort: PermissionsPort
    let modelCatalog: ModelCatalogPort
    let calendar: CalendarPort
    let clock: @Sendable () -> Date

    var continuations: [AsyncStream<AppEvent>.Continuation] = []

    public init(
        meetings: MeetingRepository,
        recordings: RecordingRepository,
        transcripts: TranscriptRepository,
        persons: PersonRepository,
        permissions: PermissionsPort,
        modelCatalog: ModelCatalogPort,
        calendar: CalendarPort,
        clock: @escaping @Sendable () -> Date = Date.init
    ) {
        self.meetingRepository = meetings
        self.recordings = recordings
        self.transcripts = transcripts
        self.persons = persons
        self.permissionsPort = permissions
        self.modelCatalog = modelCatalog
        self.calendar = calendar
        self.clock = clock
    }

    /// Отказ методов, которых эта часть PR не реализует — см. заголовок файла.
    func notImplemented(_ method: String, group: String) -> AppFacadeError {
        .notAllowed(reason: "AppFacadeImpl.\(method) — реализация группы «\(group)» плана MEE-410 ждёт своего PR")
    }

    // MARK: - Чтение: сквозные обёртки, дословно однозначные (§«Поведение»)

    public func permissions() async -> PermissionSnapshot {
        await permissionsPort.snapshot()
    }

    public func models() async -> [ModelDescriptor] {
        await modelCatalog.models()
    }

    public func modelState(id: String, version: String) async -> ModelState {
        await modelCatalog.state(id: id, version: version)
    }

    public func profiles() async -> [TranscriptionProfile] {
        await modelCatalog.profiles()
    }

    public func syncCalendars() async -> [CalendarSyncResult] {
        await calendar.sync(trigger: .manual)
    }

    public func requestPermission(_ kind: PermissionKind) async -> PermissionRequestOutcome {
        await permissionsPort.request(kind)
    }

    public func cancelModelDownload(id: String, version: String) async {
        await modelCatalog.cancelDownload(id: id, version: version)
    }

    /// К48(б), MEE-410 группа Х, действующий текст `c8741abd`: `code ==
    /// "permissions.settingsPaneUnavailable"`, `permissionKind == nil` — дословно по
    /// критерию, а не по семантике поля `PermissionsError.settingsPaneUnavailable(kind:)`.
    public func openPermissionSettings(_ kind: PermissionKind) async throws {
        do {
            try await permissionsPort.openSettings(for: kind)
        } catch let error as PermissionsError {
            throw wrap(error)
        }
    }

    private func wrap(_ error: PermissionsError) -> AppFacadeError {
        let code: String
        switch error {
        case .loginItemRegistrationFailed: code = "permissions.loginItemRegistrationFailed"
        case .settingsPaneUnavailable: code = "permissions.settingsPaneUnavailable"
        }
        return .underlying(AppErrorView(
            code: code, message: String(describing: error), recoverySuggestion: nil, permissionKind: nil
        ))
    }

    // MARK: - `status()` — минимальная реализация, см. заголовок файла

    public func status() async -> AppStatus {
        let upcomingItems = (try? await meetingListItems(from: clock(), to: .distantFuture)) ?? []
        return AppStatus(
            activeSession: nil,
            upcoming: upcomingItems,
            runningJobs: [],
            pendingJobCount: 0,
            failedJobCount: 0,
            permissionsReady: .notReady,
            connectors: [],
            updatedAt: clock()
        )
    }

    // MARK: - Поток событий (инв. 15, 16) — оснастка; наполнение публикациями идёт вместе с командами

    public func events() -> AsyncStream<AppEvent> {
        AsyncStream { continuation in
            continuations.append(continuation)
        }
    }

    func publish(_ event: AppEvent) {
        for continuation in continuations {
            continuation.yield(event)
        }
    }
}
