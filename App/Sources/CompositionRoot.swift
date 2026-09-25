//  CompositionRoot — единственное место, где граф модулей domain-core связывается с
//  production-реализациями портов (MEE-433; записка архитектора MEE-430, комментарий
//  `38443994` §3, с решениями РП по найденным пробелам, MEE-433 §«Решения РП»). Строит граф
//  ровно один раз при старте `MeetForMeApp` и не выставляет наружу ничего, кроме `AppGraph`
//  (готовый `AppFacade` + то немногое, чем управляет жизненным циклом сам composition root).
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: composition root
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

import CalendarEventKit
import CalendarHub
import Capture
import Detector
import DomainCore
import Foundation
import Permissions
import SecretStoreKeychain
import Storage

/// Готовый граф: единственное, что получает `MeetForMeApp` наружу.
struct AppGraph: Sendable {
    let facade: AppFacade
    private let sessionMachine: SessionMachine
    private let jobQueue: JobQueueEngine

    fileprivate init(facade: AppFacade, sessionMachine: SessionMachine, jobQueue: JobQueueEngine) {
        self.facade = facade
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
    /// бандл-ресурс, повреждённая строка настроек) — вызывающая сторона показывает нативный
    /// alert и завершает процесс (решение архитектора, MEE-430 «жизненный цикл»), а не
    /// продолжает с частично собранным графом.
    static func build() async throws -> AppGraph {
        // Шаг 1 — хранилище.
        let fileLayout = FileLayout(root: try applicationSupportRoot())
        try FileManager.default.createDirectory(at: fileLayout.root, withIntermediateDirectories: true)
        let storage = try StorageDatabase(path: fileLayout.databaseURL())

        // Шаг 2 — адаптеры системы.
        let systemPermissions = SystemPermissions()
        let systemPower = SystemPower()
        // SignalWeights.current() бросает на битой таблице — часть отказа на старте (докстринг
        // файла), не try?/дефолт по месту: ресурс собственной сборки обязан существовать.
        let weights = try SignalWeights.current()
        let detector = try MeetingDetector(
            clientRunning: weights.weight(for: .clientRunning),
            clientAudioOutput: weights.weight(for: .clientAudioOutput),
            microphoneInUse: weights.weight(for: .microphoneInUse),
            signalTtlSeconds: Double(weights.signalTtlSeconds)
        )
        let secretStore = SecretStoreKeychain()
        let eventKitConnector = EventKitConnector(permissions: systemPermissions, platformResolver: detector)

        // Шаг 3 — calendar-hub. `SystemWaitSeam` — производственный шов (MEE-433, решение
        // РП п.2): реальный `Task.sleep`, единственная реализация `WaitSeam` в продукте.
        let calendarPort = CalendarPortImpl(
            connectorRepository: storage.connectorRepository(),
            meetingRepository: storage.meetingRepository(),
            waitSeam: SystemWaitSeam(),
            secretStore: secretStore,
            // "eventkit" — идентификатор, названный докстрингом самого CalendarSourceId
            // (CalendarPort.swift:37) как пример локального коннектора; Outlook (Plugins/graph)
            // — вне Среза 1 (module-map.md §6).
            connectors: [CalendarSourceId(rawValue: "eventkit"): eventKitConnector]
        )

        // Шаг 4 — attribution.
        let attribution = SpeakerAttribution()

        // Шаг 5 — очередь (создание; регистрация обработчиков — после шага 7, см. шапку файла).
        // `ModelCatalogPort` — временная заглушка до MEE-429 (MEE-433, решение п.5).
        let modelCatalog = TemporaryModelCatalogStub()
        let jobQueue = JobQueueEngine(
            repository: storage.jobRepository(),
            modelCatalog: modelCatalog,
            powerPort: systemPower,
            clock: { Date() }
        )

        // Шаг 6 — оркестрация сессии.
        let settings = try await loadSettings(from: storage.settingsRepository())
        let sessionMachine = SessionMachine(
            processes: detector,
            calendar: calendarPort,
            meetings: storage.meetingRepository(),
            recordings: storage.recordingRepository(fileLayout: fileLayout),
            transcripts: storage.transcriptRepository(),
            capture: AudioCaptureImpl(power: systemPower),
            queue: jobQueue,
            power: systemPower,
            settings: settings,
            weights: weights,
            recordingDirectory: { id in fileLayout.recordingDirectory(id.uuidString) },
            // Срез 1 не даёт настройке выбора устройства своего поля в AppSettings.slice1Defaults
            // (MEE-430 §3) — выбор конкретного uid остаётся за пределами этой задачи.
            captureInput: .systemDefault,
            // MEE-433, решение РП п.4 (форматы захвата — выбор DEV-1, сверка с C-004): сам порт
            // (Packages/Mac/Sources/Capture) не фиксирует аппаратный формат — CaptureRequest
            // несёт его параметром, а тракт ремаплирует канал на лету (AudioCaptureImplBuffers.
            // swift:24, CoreAudioAggregate.swift) под то, что попросили. Число не хранилищное
            // (architecture.md называет только итоговый AAC при записи, не формат захвата) —
            // 48 000 Гц/стерео для системного трека (голоса собеседников в звонке — до двух
            // сторон стереопанорамы), 48 000 Гц/моно для микрофона (один говорящий) — тот же
            // приём, что уже применён к AppSettings.slice1Defaults (IR-105): выбор назван здесь.
            systemFormat: TrackFormat(sampleRate: 48_000, channelCount: 2),
            micFormat: TrackFormat(sampleRate: 48_000, channelCount: 1)
        )

        // Шаг 7 — фасад. Единственный экземпляр AppFacade.
        let facade = AppFacadeImpl(
            meetings: storage.meetingRepository(),
            recordings: storage.recordingRepository(fileLayout: fileLayout),
            transcripts: storage.transcriptRepository(),
            persons: storage.personRepository(),
            speakerProfiles: storage.speakerProfileRepository(),
            permissions: systemPermissions,
            modelCatalog: modelCatalog,
            calendar: calendarPort,
            sessionCoordinator: sessionMachine,
            attribution: attribution,
            settings: storage.settingsRepository()
        )

        // Регистрация обработчиков — после фасада (шапка файла). `TranscriptionServicePort` —
        // временная заглушка до MEE-431 (MEE-433, решение п.5): EngineKit/Fakes не несёт
        // готового конформера этого порта — `LoopbackEngineTransport` разбирает
        // `EngineRequest`/`EngineReply`, другой уровень, не `transcribe(_:progress:)` напрямую.
        await registerOrCrash(TranscribeJobHandler(port: TemporaryTranscriptionServiceStub()), into: jobQueue)
        await registerOrCrash(
            AttributeJobHandler(
                port: attribution,
                transcripts: storage.transcriptRepository(),
                meetings: storage.meetingRepository(),
                persons: storage.personRepository(),
                speakerProfiles: storage.speakerProfileRepository(),
                appFacade: facade
            ),
            into: jobQueue
        )

        // Старт. Очередь — первой (сама восстанавливает прерванные задачи, JobQueueEngineLifecycle.
        // swift, recoverInterruptedJobs()); машина сессии — второй (восстановление §10, подписки
        // на входы §2, см. шапку файла).
        await jobQueue.start()
        await sessionMachine.start(now: Date())

        return AppGraph(facade: facade, sessionMachine: sessionMachine, jobQueue: jobQueue)
    }

    /// `~/Library/Application Support/<bundle-id>` — каталог должен существовать (модуль
    /// `Storage` его не создаёт, см. `FileLayout` докстринг), composition root заводит его сам.
    private static func applicationSupportRoot() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else {
            throw CompositionRootError.applicationSupportDirectoryUnavailable
        }
        let bundleId = Bundle.main.bundleIdentifier ?? "com.andreeyka.meetforme"
        return base.appendingPathComponent(bundleId, isDirectory: true)
    }

    /// Снимок `AppSettings` при старте — composition root читает `SettingsRepository`
    /// НАПРЯМУЮ, не через `AppFacade.settings()`: на этом шаге фасада ещё не существует (шаг
    /// 7, позже). Повторяет схему чтения `AppFacadeImpl.settings()` (C-016 §2.1 — ключ есть
    /// имя поля дословно) вместо вызова общей функции: `settingsField` приватна расширению
    /// `AppFacadeImpl+Settings.swift`, а заводить публичную обёртку в `domain-core` — за
    /// пределами этой задачи (composition root, `App/`). Известное небольшое дублирование, не
    /// случайное. `SessionMachine.settings` — `let`: применяется со следующего запуска
    /// приложения (MEE-433, решение РП п.3; живые настройки — IR-138, MEE-434, не блокирует).
    private static func loadSettings(from repository: SettingsRepository) async throws -> AppSettings {
        let defaults = AppSettings.slice1Defaults
        return AppSettings(
            recordingPolicy: try await field(
                AppSettings.RecordingPolicy.self, "recordingPolicy", defaults.recordingPolicy, repository
            ),
            armLeadSeconds: try await field(Int.self, "armLeadSeconds", defaults.armLeadSeconds, repository),
            askLeadSeconds: try await field(Int.self, "askLeadSeconds", defaults.askLeadSeconds, repository),
            missingSignalGraceSeconds: try await field(
                Int.self, "missingSignalGraceSeconds", defaults.missingSignalGraceSeconds, repository
            ),
            silenceStopSeconds: try await field(
                Int.self, "silenceStopSeconds", defaults.silenceStopSeconds, repository
            ),
            defaultProfileId: try await field(
                String.self, "defaultProfileId", defaults.defaultProfileId, repository
            ),
            processOnACPowerOnly: try await field(
                Bool.self, "processOnACPowerOnly", defaults.processOnACPowerOnly, repository
            ),
            processWhileRecording: try await field(
                Bool.self, "processWhileRecording", defaults.processWhileRecording, repository
            ),
            audioRetentionDays: try await field(
                Int?.self, "audioRetentionDays", defaults.audioRetentionDays, repository
            ),
            voiceProfilesEnabled: try await field(
                Bool.self, "voiceProfilesEnabled", defaults.voiceProfilesEnabled, repository
            ),
            notifyParticipants: try await field(
                Bool.self, "notifyParticipants", defaults.notifyParticipants, repository
            ),
            launchAtLogin: try await field(Bool.self, "launchAtLogin", defaults.launchAtLogin, repository)
        )
    }

    private static func field<Value: Codable>(
        _ type: Value.Type, _ key: String, _ defaultValue: Value, _ repository: SettingsRepository
    ) async throws -> Value {
        guard let data = try await repository.value(forKey: key) else { return defaultValue }
        guard let decoded = try? DomainJSON.decode(Value.self, from: data) else {
            throw CompositionRootError.settingsUnreadable(key: key)
        }
        return decoded
    }

    /// `register(handler:)` бросает только на дублирующем типе обработчика — отказ
    /// программирования (composition root регистрирует каждый тип ровно один раз по
    /// построению), не окружения (MEE-430 «жизненный цикл», решение архитектора).
    private static func registerOrCrash(_ handler: JobHandler, into queue: JobQueueEngine) async {
        do {
            try await queue.register(handler: handler)
        } catch {
            fatalError("CompositionRoot: регистрация обработчика отказала — отказ программирования: \(error)")
        }
    }
}
