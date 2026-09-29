//  CompositionRoot+Steps — шаги 1-7 записки MEE-430 §3 (комментарий `38443994`, финальная
//  редакция) + регистрация обработчиков очереди (MEE-433, решение РП п.1). Разведено из
//  `CompositionRoot.swift` по объёму (`type_body_length`/`function_body_length`), не по
//  смыслу — тем же приёмом, что уже стоит в дереве (`SpeakerAttribution.swift` докстринг).
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: composition root

import Attribution
import CalendarEventKit
import CalendarHub
import Capture
import Detector
import DomainCore
import EngineXPCClient
import Foundation
import ModelManager
import Permissions
import SecretStoreKeychain
import Storage

extension CompositionRoot {

    // MARK: - Шаг 1 — хранилище

    struct StorageContext {
        let fileLayout: FileLayout
        let storage: StorageDatabase
    }

    static func makeStorageContext() throws -> StorageContext {
        let fileLayout = FileLayout(root: try applicationSupportRoot())
        try FileManager.default.createDirectory(at: fileLayout.root, withIntermediateDirectories: true)
        return StorageContext(fileLayout: fileLayout, storage: try StorageDatabase(path: fileLayout.databaseURL()))
    }

    // MARK: - Шаг 2 — адаптеры системы

    struct SystemAdapters {
        let permissions: SystemPermissions
        let power: SystemPower
        let weights: SignalWeights
        let detector: MeetingDetector
        let secretStore: SecretStoreKeychain
        let eventKitConnector: EventKitConnector
    }

    static func makeSystemAdapters() throws -> SystemAdapters {
        let permissions = SystemPermissions()
        let power = SystemPower()
        // SignalWeights.current() бросает на битой таблице — часть отказа на старте (шапка
        // CompositionRoot.swift), не try?/дефолт по месту: ресурс собственной сборки обязан
        // существовать.
        let weights = try SignalWeights.current()
        let detector = try MeetingDetector(
            clientRunning: weights.weight(for: .clientRunning),
            clientAudioOutput: weights.weight(for: .clientAudioOutput),
            microphoneInUse: weights.weight(for: .microphoneInUse),
            signalTtlSeconds: Double(weights.signalTtlSeconds)
        )
        let secretStore = SecretStoreKeychain()
        let eventKitConnector = EventKitConnector(permissions: permissions, platformResolver: detector)
        return SystemAdapters(
            permissions: permissions, power: power, weights: weights, detector: detector,
            secretStore: secretStore, eventKitConnector: eventKitConnector
        )
    }

    // MARK: - Накопитель шагов 1-5

    /// Всё, что шаги 1-5 успели построить, — одним значением, не по параметру на функцию
    /// (`function_parameter_count`): дальше по графу нужны разные подмножества сразу.
    struct PartialGraph {
        let context: StorageContext
        let adapters: SystemAdapters
        let calendarPort: CalendarPortImpl
        let attribution: SpeakerAttribution
        /// Один экземпляр на граф: фасад и `ModelCatalogManager` делят его (C-014 v7, инв. 37).
        let settings: SettingsRepository
        let modelCatalog: ModelCatalogManager
        let jobQueue: JobQueueEngine
    }

    // MARK: - Шаг 3 — calendar-hub

    /// `SystemWaitSeam` — производственный шов (MEE-433, решение РП п.2): реальный
    /// `Task.sleep`, единственная реализация `WaitSeam` в продукте.
    static func makeCalendarPort(context: StorageContext, adapters: SystemAdapters) -> CalendarPortImpl {
        CalendarPortImpl(
            connectorRepository: context.storage.connectorRepository(),
            meetingRepository: context.storage.meetingRepository(),
            waitSeam: SystemWaitSeam(),
            secretStore: adapters.secretStore,
            // "eventkit" — идентификатор, названный докстрингом самого CalendarSourceId
            // (CalendarPort.swift:37) как пример локального коннектора; Outlook (Plugins/graph)
            // — вне Среза 1 (module-map.md §6).
            connectors: [CalendarSourceId(rawValue: "eventkit"): adapters.eventKitConnector]
        )
    }

    // MARK: - Шаг 6 — оркестрация сессии

    static func makeSessionMachine(
        _ partial: PartialGraph, settings: AppSettings, capture: AudioCapturePort
    ) -> SessionMachine {
        let storage = partial.context.storage
        let recordings = storage.recordingRepository(fileLayout: partial.context.fileLayout)
        return SessionMachine(
            processes: partial.adapters.detector,
            calendar: partial.calendarPort,
            meetings: storage.meetingRepository(),
            recordings: recordings,
            transcripts: storage.transcriptRepository(),
            capture: capture,
            queue: partial.jobQueue,
            power: partial.adapters.power,
            settings: settings,
            weights: partial.adapters.weights,
            // MEE-440 (находка РП на приёмке composition root, MEE-434, 09:15 UTC): Б1
            // (возврат РП, MEE-433) чинился здесь ad hoc, `try?` — каталог создавал сам
            // composition root, глотая отказ файловой системы молча. Решение архитектора:
            // создание каталога — обязанность `storage` (симметрично удалению, которое он уже
            // делает), не этого файла. `SessionMachine.recordingDirectory` теперь `async throws`
            // (тот же MEE-440) — отказ `createDirectory` доходит до `enterRecording` как есть,
            // не подменяется на «отказ записи тем же путём, но на шаг позже, без причины».
            recordingDirectory: { id in try await recordings.createDirectory(recordingId: id) },
            // Срез 1 не даёт настройке выбора устройства своего поля в
            // AppSettings.slice1Defaults (MEE-430 §3) — выбор конкретного uid остаётся за
            // пределами этой задачи.
            captureInput: .systemDefault,
            // MEE-433, решение РП п.4 (форматы захвата — выбор DEV-1, сверка с C-004): сам
            // порт (Packages/Mac/Sources/Capture) не фиксирует аппаратный формат —
            // CaptureRequest несёт его параметром, тракт ремаплирует канал на лету
            // (AudioCaptureImplBuffers.swift:24, CoreAudioAggregate.swift) под то, что
            // попросили. Число не хранилищное (architecture.md называет только итоговый AAC
            // при записи, не формат захвата) — 48 000 Гц/стерео для системного трека (голоса
            // собеседников в звонке — до двух сторон стереопанорамы), 48 000 Гц/моно для
            // микрофона (один говорящий) — тот же приём, что уже применён к
            // AppSettings.slice1Defaults (IR-105): выбор назван здесь.
            systemFormat: TrackFormat(sampleRate: 48_000, channelCount: 2),
            micFormat: TrackFormat(sampleRate: 48_000, channelCount: 1)
        )
    }

    // MARK: - Шаг 7 — фасад

    static func makeFacade(
        _ partial: PartialGraph, sessionMachine: SessionMachine, capture: AudioCapturePort
    ) -> AppFacadeImpl {
        let storage = partial.context.storage
        return AppFacadeImpl(
            meetings: storage.meetingRepository(),
            recordings: storage.recordingRepository(fileLayout: partial.context.fileLayout),
            transcripts: storage.transcriptRepository(),
            persons: storage.personRepository(),
            speakerProfiles: storage.speakerProfileRepository(),
            permissions: partial.adapters.permissions,
            modelCatalog: partial.modelCatalog,
            calendar: partial.calendarPort,
            sessionCoordinator: sessionMachine,
            attribution: partial.attribution,
            settings: partial.settings,
            connectors: storage.connectorRepository(),
            capture: capture,
            jobQueue: partial.jobQueue,
            fileLayout: partial.context.fileLayout
        )
    }

    // MARK: - Регистрация обработчиков (после шага 7 — шапка CompositionRoot.swift)

    /// `TranscriptionServicePort` — `EngineXPCClient` (MEE-472): один экземпляр на граф, виден
    /// только `TranscribeJobHandler` (П7: App не зовёт движок мимо домена). Каталог — тот же
    /// `ModelCatalogManager`, что у очереди и фасада (C-012 «Поведение», C-014 §4.1): расписки
    /// `beginUse`/`endUse` клиента попадают туда, куда смотрит фасад. Соединением владеет сам
    /// клиент (записка MEE-430 §3) — лениво, при первом запросе; `AppGraph.shutdown` его не
    /// трогает, у C-012 нет `close`.
    static func registerHandlers(_ partial: PartialGraph, facade: AppFacadeImpl) async {
        let storage = partial.context.storage
        let engineClient = EngineXPCClient(
            serviceName: transcriptionEngineServiceName(), modelCatalog: partial.modelCatalog
        )
        await registerOrCrash(TranscodeJobHandler(), into: partial.jobQueue)
        await registerOrCrash(
            TranscribeJobHandler(port: engineClient, transcripts: storage.transcriptRepository()),
            into: partial.jobQueue
        )
        await registerOrCrash(DiarizeJobHandler(), into: partial.jobQueue)
        await registerOrCrash(
            AttributeJobHandler(
                port: partial.attribution,
                transcripts: storage.transcriptRepository(),
                meetings: storage.meetingRepository(),
                persons: storage.personRepository(),
                speakerProfiles: storage.speakerProfileRepository(),
                appFacade: facade
            ),
            into: partial.jobQueue
        )
    }
}
