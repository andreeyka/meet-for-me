//  AppFacadeImpl — реализация `AppFacade` (C-016 v10, MEE-25) поверх настоящих портов и
//  репозиториев. MEE-420 часть 4 (план MEE-410): группа Г — `editSegmentText` (К13-К14),
//  поверх частей 1-3 (группы А, Б, В, Х-К48б, слитых #145/#151). Несколько мелких, дословно
//  однозначных сквозных обёрток (§«Поведение»: «фасад — тонкий слой сборки… вызывает порты
//  и репозитории») реализованы попутно, потому что риск ошибки в них тот же, что у уже
//  проверенных методов, — их приёмка в этом PR не заявляется, тесты для них заводит
//  соответствующая группа плана.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  `startRecording`/`stopRecording` — тонкая обёртка над `SessionCoordinator` (C-018): его
//  собственный комментарий называет эти методы вызываемыми фасадом («их зовёт фасад C-016
//  §4»), а `SessionMachine` (настоящая реализация `SessionCoordinator`) уже владеет
//  композицией `RecordingRepository`+`AudioCapturePort` — фасаду не нужно трогать их
//  напрямую. Проверка права (инв. 10) и активной сессии (инв. 9) — перед вызовом
//  `SessionCoordinator`, а не внутри него: `SessionError` не несёт кейса про право, а
//  «активная сессия» проверяется явным чтением `sessions()`, не сведена в отдельный throw
//  у фейка/машины на этот случай.
//
//  ЧТО НЕ РЕАЛИЗОВАНО ЭТИМ PR, И ПОЧЕМУ ЭТО НЕ НЕДОДЕЛКА. Оставшиеся ~22 метода
//  протокола (группы Д-Ц плана, кроме уже названных сквозных обёрток и групп В/Г) бросают
//  `notImplemented(_:)` — самоописывающийся отказ, а не молчаливая заглушка: вызвать их
//  сегодня физически некому — `App/` (композиционный корень, единственное место, что
//  создаёт `AppFacadeImpl`) не существует ни одним файлом (план MEE-410 §7, слой 3), и до
//  его появления эти методы мертвы для продакшена, а не только для тестов. Реализация
//  каждой группы — предмет своего PR, по прямому разрешению постановки МЕЕ-420
//  («можно разбить фасад на несколько PR по группам плана»). `skipMeeting` (группа Х, К47)
//  остаётся стоп-заглушкой — РП назвал следующей работой запись/обработку/атрибуцию/
//  календарь/настройки/события, не группу Х целиком.
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
    let sessionCoordinator: SessionCoordinator
    let clock: @Sendable () -> Date

    nonisolated let broadcaster = AppEventBroadcaster()

    public init(
        meetings: MeetingRepository,
        recordings: RecordingRepository,
        transcripts: TranscriptRepository,
        persons: PersonRepository,
        permissions: PermissionsPort,
        modelCatalog: ModelCatalogPort,
        calendar: CalendarPort,
        sessionCoordinator: SessionCoordinator,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.meetingRepository = meetings
        self.recordings = recordings
        self.transcripts = transcripts
        self.persons = persons
        self.permissionsPort = permissions
        self.modelCatalog = modelCatalog
        self.calendar = calendar
        self.sessionCoordinator = sessionCoordinator
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
        } catch {
            throw wrapUnexpected(error)
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

    /// Инв. 19, §3.1: ошибки снизу вне словаря §3.1 (например `DomainValidationError`,
    /// `DecodingError`) не должны уходить наружу как есть — приёмка `bf060b8` вернула это
    /// как пропуск. Сводим их к `.underlying` с кодом `app.internalError`, а не к тому, что
    /// не сможет разобрать вызывающая сторона.
    func wrapUnexpected(_ error: Error) -> AppFacadeError {
        .underlying(AppErrorView(
            code: "app.internalError", message: String(describing: error), recoverySuggestion: nil, permissionKind: nil
        ))
    }

    // MARK: - editSegmentText (группа Г плана MEE-410; К13, К14)

    /// К13 (инв. 13, часть 1): ровно один вызов `TranscriptRepository.updateSegmentText(
    /// isUserEdited: true)`, без `applyTextCorrections` — правка целиком заменяет текст
    /// сегмента, а не накладывает список точечных замен слов (`applyTextCorrections` сама
    /// пишет `is_user_edited = 0` — см. `Repositories.swift` — для правок распознавания,
    /// не для ручного редактирования целиком). К14: повторная правка того же сегмента идёт
    /// тем же путём, не переключается на `applyTextCorrections`.
    public func editSegmentText(segmentId: Int64, text: String) async throws {
        do {
            try await transcripts.updateSegmentText(segmentId: segmentId, text: text, isUserEdited: true)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
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

    /// `events()` в контракте (§2) не `async` — актор обязан отдать такой метод `nonisolated`,
    /// тем же приёмом, что `JobQueueEngine.events()`/`SessionMachine.changes()`. Состояние
    /// подписчиков поэтому живёт в `AppEventBroadcaster`, отдельном классе с замком, а не в акторе.
    public nonisolated func events() -> AsyncStream<AppEvent> {
        broadcaster.subscribe()
    }

    func publish(_ event: AppEvent) {
        broadcaster.publish(event)
    }
}

/// См. комментарий у `AppFacadeImpl.events()`. Тот же приём, что `JobEventBroadcaster`.
final class AppEventBroadcaster: @unchecked Sendable {

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<AppEvent>.Continuation] = [:]

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    func subscribe() -> AsyncStream<AppEvent> {
        AsyncStream { continuation in
            let subscriptionId = UUID()
            locked { continuations[subscriptionId] = continuation }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.locked { self.continuations[subscriptionId] = nil }
            }
        }
    }

    func publish(_ event: AppEvent) {
        let targets = locked { Array(continuations.values) }
        for continuation in targets {
            continuation.yield(event)
        }
    }
}
