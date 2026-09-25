//  CompositionRoot — единственное место, где граф модулей domain-core связывается с
//  production-реализациями портов (MEE-433; записка архитектора MEE-430, комментарий
//  `38443994` §3, с решениями РП по найденным пробелам, MEE-433 §«Решения РП»). Строит граф
//  ровно один раз при старте `MeetForMeApp` и не выставляет наружу ничего, кроме `AppGraph`
//  (готовый `AppFacade` + то немногое, чем управляет жизненным циклом сам composition root).
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: composition root
//
//  Шаги 1-7 — в `CompositionRoot+Steps.swift`, снимок настроек — в
//  `CompositionRoot+Settings.swift`: разведено по файлам, не по смыслу (`type_body_length`),
//  тем же приёмом, что уже стоит в дереве (`SpeakerAttribution.swift` докстринг).
//
//  ПОРЯДОК ШАГОВ — записка МЕЕ-430 §3, с одной правкой РП (MEE-433, решение п.1): регистрация
//  обработчиков очереди идёт ПОСЛЕ шага 7 (фасад), не на шаге 5 (очередь) — `AttributeJobHandler`
//  требует уже готовый `AppFacade` (круговая зависимость, найденная этой же сессией, MEE-430
//  комментарий `00871c0d`). Само создание очереди — по-прежнему на шаге 5.
//
//  ЖИЗНЕННЫЙ ЦИКЛ `SessionCoordinator` (`sessionMachine.start(now:)`/`.stop()`) — решение этой
//  сессии, не записки: записка МЕЕ-430 называет жизненный цикл `JobQueueEngine`, но ни разу не
//  упоминает `SessionCoordinator.start(now:)`/`.stop()` (протокол их объявляет —
//  `SessionCoordinator.swift:139,141` — «восстановление §10, подписки на входы §2»), а
//  `AppFacadeImpl` их нигде не зовёт сама (сверено чтением `AppFacadeImpl+Recording.swift` —
//  там только `startRecording`/`stopRecording`, разные методы). Без явного вызова граф
//  компилируется, но восстановление и подписки на входы не включаются никогда.

import Attribution
import DomainCore
import Foundation
import Storage

/// Готовый граф: единственное, что получает `MeetForMeApp` наружу.
struct AppGraph: Sendable {
    let facade: AppFacade
    /// IR-140 (MEE-439): строка настроек на старте была нечитаемой, подставлены
    /// `AppSettings.slice1Defaults` — вызывающая сторона (`AppDelegate`) показывает
    /// одноразовое уведомление ровно один раз, сразу после получения графа.
    let settingsUsedDefaults: Bool
    private let sessionMachine: SessionMachine
    private let jobQueue: JobQueueEngine

    fileprivate init(
        facade: AppFacade, settingsUsedDefaults: Bool, sessionMachine: SessionMachine, jobQueue: JobQueueEngine
    ) {
        self.facade = facade
        self.settingsUsedDefaults = settingsUsedDefaults
        self.sessionMachine = sessionMachine
        self.jobQueue = jobQueue
    }

    /// Останов при завершении приложения — вызывающая сторона (`AppDelegate`) ждёт её перед
    /// тем, как разрешить процессу выйти (`applicationShouldTerminate`, `.terminateLater`).
    func shutdown() async {
        await sessionMachine.stop()
        await jobQueue.stop()
    }
}

enum CompositionRootError: Error, LocalizedError, Sendable {
    case applicationSupportDirectoryUnavailable
    case settingsUnreadable(key: String)

    var errorDescription: String? {
        switch self {
        case .applicationSupportDirectoryUnavailable:
            return "не удалось определить каталог Application Support"
        case .settingsUnreadable(let key):
            return "настройка \"\(key)\" повреждена в хранилище — байты есть, но не разбираются"
        }
    }
}

enum CompositionRoot {

    /// Строит граф. Бросает на сломанном окружении (диск, права каталога, повреждённый
    /// бандл-ресурс) — вызывающая сторона показывает нативный alert и завершает процесс
    /// (решение архитектора, MEE-430 «жизненный цикл»), а не продолжает с частично собранным
    /// графом. Повреждённая СТРОКА НАСТРОЕК — исключение из этого правила (IR-140, MEE-439,
    /// решение архитектора): не бросает, подставляет `AppSettings.slice1Defaults`
    /// (`loadSettingsForStartup`, `CompositionRoot+Settings.swift`) — восстановиться есть чем,
    /// в отличие от диска/каталога/`StorageDatabase`/`SignalWeights`.
    static func build() async throws -> AppGraph {
        let context = try makeStorageContext()
        let adapters = try makeSystemAdapters()
        let calendarPort = makeCalendarPort(context: context, adapters: adapters)
        let attribution = SpeakerAttribution()
        let modelCatalog = TemporaryModelCatalogStub()
        let jobQueue = JobQueueEngine(
            repository: context.storage.jobRepository(), modelCatalog: modelCatalog,
            powerPort: adapters.power, clock: { Date() }
        )
        let partial = PartialGraph(
            context: context, adapters: adapters, calendarPort: calendarPort,
            attribution: attribution, modelCatalog: modelCatalog, jobQueue: jobQueue
        )

        let startupSettings = try await loadSettingsForStartup(from: context.storage.settingsRepository())
        let sessionMachine = makeSessionMachine(partial, settings: startupSettings.settings)
        let facade = makeFacade(partial, sessionMachine: sessionMachine)

        await registerHandlers(partial, facade: facade)

        // Очередь — первой (сама восстанавливает прерванные задачи,
        // JobQueueEngineLifecycle.swift, recoverInterruptedJobs()); машина сессии — второй
        // (восстановление §10, подписки на входы §2, см. шапку файла).
        await jobQueue.start()
        await sessionMachine.start(now: Date())

        return AppGraph(
            facade: facade, settingsUsedDefaults: startupSettings.usedDefaults,
            sessionMachine: sessionMachine, jobQueue: jobQueue
        )
    }

    /// `~/Library/Application Support/<bundle-id>` — каталог должен существовать (модуль
    /// `Storage` его не создаёт, см. `FileLayout` докстринг), composition root заводит его сам.
    static func applicationSupportRoot() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw CompositionRootError.applicationSupportDirectoryUnavailable
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.andreeyka.meetforme"
        return base.appendingPathComponent(bundleId, isDirectory: true)
    }

    /// `register(handler:)` бросает только на дублирующем типе обработчика — отказ
    /// программирования (composition root регистрирует каждый тип ровно один раз по
    /// построению), не окружения (MEE-430 «жизненный цикл», решение архитектора).
    static func registerOrCrash(_ handler: JobHandler, into queue: JobQueueEngine) async {
        do {
            try await queue.register(handler: handler)
        } catch {
            fatalError("CompositionRoot: регистрация обработчика отказала — отказ программирования: \(error)")
        }
    }
}
