//  Ожидаемые блоки контрактов для `PortDeclarationTests` — дословные копии разделов
//  «Определение» контрактов-владельцев, в их порядке. Проверки сами живут в
//  `PortDeclarationTests.swift`; это один и тот же тип `PortDeclarationTests`,
//  расширенный вторым файлом.
//
//  ПОЧЕМУ ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ЧАСТЬ `PortDeclarationTests.swift`. Причина
//  техническая: восемнадцать статических массивов (дописаны MEE-346), структура
//  `PortContract` и сам список `contracts` вместе с телом тестов одним файлом
//  превышали и порог `file_length`, и порог `type_body_length` SwiftLint (--strict,
//  работа «Core + Mac», прогон CI). Деление — по объёму, а не по смыслу: `extension`
//  расширяет тот же тип `PortDeclarationTests`, что и соседний файл, а не заводит
//  другой.

import Foundation

extension PortDeclarationTests {

    /// C-004 (MEE-77), «Определение» §4.
    static let audioCapturePort = [
        "func start(_ request: CaptureRequest) async throws -> CaptureStarted",
        "func stop() async throws -> RecordingManifest",
        "func pause() async throws",
        "func resume() async throws",
        "func setInput(_ selection: InputSelection) async throws",
        "func events() -> AsyncStream<CaptureEvent>",
        "func recover(directory: URL) async throws -> RecordingManifest"
    ]

    /// C-005 (MEE-9), «Определение».
    static let calendarPort = [
        "func listSources() async -> [CalendarSourceId]",
        "func listCalendars(source: CalendarSourceId) async throws -> [CalendarInfo]",
        "func setSelectedCalendars(source: CalendarSourceId, calendarIds: [String]) async throws",
        "func events(from: Date, to: Date) async throws -> [MeetingEvent]",
        "func event(id: UUID) async throws -> MeetingEvent?",
        "func sync(trigger: CalendarSyncTrigger) async -> [CalendarSyncResult]",
        "func changes() -> AsyncStream<CalendarChange>"
    ]

    /// C-010 (MEE-18), «Определение» §5.
    static let meetingRepository = [
        "func save(_ record: MeetingRecord) async throws",
        "func meeting(id: UUID) async throws -> MeetingRecord?",
        "func meeting(dedupKey: DedupKey) async throws -> MeetingRecord?",
        "func meetings(from: Date, to: Date) async throws -> [MeetingRecord]",
        "func setStatus(_ status: MeetingStatus, meetingId: UUID) async throws",
        "func delete(meetingIds: [UUID]) async throws"
    ]

    static let recordingRepository = [
        "func save(_ record: RecordingRecord) async throws",
        "func recording(id: UUID) async throws -> RecordingRecord?",
        "func recordings(meetingId: UUID) async throws -> [RecordingRecord]",
        "func unfinalized() async throws -> [RecordingRecord]",
        "func adHoc() async throws -> [RecordingRecord]",
        "func delete(recordingId: UUID, deleteFiles: Bool) async throws"
    ]

    static let transcriptRepository = [
        "func save(_ transcript: Transcript) async throws -> TranscriptHeader",
        "func headers(recordingId: UUID) async throws -> [TranscriptHeader]",
        "func latest(recordingId: UUID) async throws -> TranscriptHeader?",
        "func transcript(id: UUID) async throws -> Transcript?",
        "func segments(transcriptId: UUID) async throws -> [SegmentRow]",
        "func updateAttribution(_ updates: [SegmentAttributionUpdate]) async throws",
        "func updateSegmentText(segmentId: Int64, text: String, isUserEdited: Bool) async throws",
        "func search(query: String, limit: Int, offset: Int) async throws -> [SearchHit]"
    ]

    /// C-010 (MEE-18) v7, «Определение» §5 — дописаны MEE-319.
    static let personRepository = [
        "func upsert(displayName: String, emails: [String]) async throws -> UUID",
        "func person(id: UUID) async throws -> PersonRecord?",
        "func person(email: String) async throws -> PersonRecord?",
        "func persons(ids: [UUID]) async throws -> [PersonRecord]",
        "func rename(personId: UUID, displayName: String) async throws",
        "func setMe(personId: UUID) async throws",
        "func me() async throws -> PersonRecord?",
        "func addNameForms(_ forms: [NameForm]) async throws",
        "func nameForms(personIds: [UUID]) async throws -> [NameForm]"
    ]

    static let speakerProfileRepository = [
        "func profile(personId: UUID, modelVersion: String) async throws -> SpeakerProfile?",
        "func profiles(personIds: [UUID], modelVersion: String) async throws -> [SpeakerProfile]",
        "func upsert(_ profile: SpeakerProfile) async throws",
        "func delete(personId: UUID) async throws",
        "func deleteAll(modelVersion: String) async throws"
    ]

    static let connectorRepository = [
        "func all() async throws -> [ConnectorRecord]",
        "func upsert(_ record: ConnectorRecord) async throws",
        "func setCursor(_ cursor: String?, connectorId: String) async throws",
        "func setSyncOutcome(at: Date, error: String?, connectorId: String) async throws",
        "func delete(connectorId: String) async throws"
    ]

    static let meetingOutputRepository = [
        "func outputs(meetingId: UUID) async throws -> [MeetingOutput]",
        "func save(_ output: MeetingOutput) async throws",
        "func markUserEdited(outputId: UUID, contentMarkdown: String) async throws"
    ]

    static let settingsRepository = [
        "func value(forKey key: String) async throws -> Data?",
        "func setValue(_ value: Data?, forKey key: String) async throws"
    ]

    /// C-013 (MEE-21), «Определение» §2.
    static let jobHandler = [
        "var type: JobType { get }",
        "func run(_ job: Job, progress: @Sendable @escaping (Double) -> Void) async -> JobOutcome"
    ]

    /// C-013 (MEE-21) v9 — `recordingDidStart`/`recordingDidStop` дописаны возвратом РП
    /// на MEE-350: прежде взяты по конвенции у конкретного типа, IR-121 закрыт архитектором.
    static let jobQueue = [
        "func register(handler: JobHandler) async throws",
        "func submit(_ submission: JobSubmission) async throws -> UUID",
        "func cancel(jobId: UUID) async throws",
        "func job(id: UUID) async throws -> Job?",
        "func jobs(status: JobStatus) async throws -> [Job]",
        "func start() async",
        "func stop() async",
        "func events() -> AsyncStream<JobEvent>",
        "func recordingDidStart() async",
        "func recordingDidStop() async"
    ]

    /// C-013 (MEE-21) v6, «Определение» §3 — дописан MEE-319.
    static let jobRepository = [
        "func insert(_ job: Job) async throws",
        "func update(_ job: Job) async throws",
        "func job(id: UUID) async throws -> Job?",
        "func jobs(status: JobStatus) async throws -> JobListing",
        "func activeJob(dedupKey: String) async throws -> Job?",
        "func claimNext(types: [JobType], excluding: Set<UUID>, now: Date, leaseSeconds: Int) async throws -> Job?",
        "func reclaimExpiredLeases(now: Date) async throws -> [Job]",
        "func failUnreadable(jobId: UUID, message: String, now: Date) async throws -> JobType?"
    ]

    /// C-013 (MEE-21) §1.1, тип возврата — C-014 v4 (MEE-22) «Определение» §4, дословно.
    /// Дописан MEE-319; тип возврата исправлен по возврату РП на приёмке MEE-319 (PR #55):
    /// был `[String]`, стало `[ModelDescriptor]`. Развилка по остальному объёму порта —
    /// комментарий над объявлением в `ModelCatalogPort.swift` (`// СТРОКА:`).
    static let modelCatalogPort = [
        "func missingModels(profileId: String) async throws -> [ModelDescriptor]"
    ]

    /// C-018 (MEE-276), «Определение» §3.1.
    static let sessionCoordinator = [
        "func sessions() async -> [SessionSnapshot]",
        "func session(id: UUID) async -> SessionSnapshot?",
        "func prompts() async -> [SessionPrompt]",
        "func changes() -> AsyncStream<SessionChange>",
        "func startRecording(meetingId: UUID?, now: Date) async throws -> UUID",
        "func stopRecording(recordingId: UUID, now: Date) async throws",
        "func skip(meetingId: UUID, now: Date) async throws",
        "func answer(promptId: UUID, _ answer: SessionPromptAnswer, now: Date) async throws",
        "func start(now: Date) async",
        "func tick(now: Date) async",
        "func stop() async"
    ]

    /// C-018 (MEE-276), «Определение» §3.2.
    static let scheduler = [
        "func plan(now: Date) async throws -> [ScheduledArm]",
        "func nextDeadline(now: Date) async throws -> Date?",
        "func start(now: Date) async",
        "func reschedule(now: Date) async",
        "func stop() async"
    ]

    /// C-006 (MEE-10) v8, §6 «Swift-зеркало для in-process коннекторов». Дописан MEE-346.
    static let connectorHostServices = [
        "func secretGet(key: String) async throws -> String?",
        "func secretSet(key: String, value: String?) async throws",
        "func log(_ level: LogLevel, _ message: String)",
        "func notify(_ kind: HostNotificationKind, detail: String?)"
    ]

    /// C-006 (MEE-10) v8, §6. Дописан MEE-346.
    static let calendarConnector = [
        "func initialize(host: ConnectorHostServices, connectorInstanceId: String) async throws " +
        "-> (PluginInfo, ConnectorCapabilities)",
        "func settingsSchema() async throws -> Data",
        "func configure(settings: Data) async throws",
        "func beginAuth() async throws -> AuthChallenge",
        "func completeAuth(callbackUrl: URL) async throws -> String?",
        "func listCalendars() async throws -> [ConnectorCalendar]",
        "func fetchEvents(from: Date, to: Date, calendarIds: [String]) async throws -> [MeetingEventPayload]",
        "func fetchChanges(cursor: String?, calendarIds: [String]) async throws -> ChangeBatch",
        "func healthCheck() async throws -> ConnectorHealth",
        "func shutdown() async"
    ]

    /// Протокол, файл его исходника и ожидаемый блок контракта.
    ///
    /// Тип, а не кортеж из трёх членов: `large_tuple` SwiftLint разрешает два,
    /// и при `--strict` третий член — отказ работы (прогон CI 140).
    struct PortContract {
        let name: String
        let file: String
        let expected: [String]
    }

    static let contracts: [PortContract] = [
        PortContract(name: "AudioCapturePort", file: "AudioCapturePort.swift", expected: audioCapturePort),
        PortContract(name: "CalendarPort", file: "CalendarPort.swift", expected: calendarPort),
        PortContract(name: "MeetingRepository", file: "Repositories.swift", expected: meetingRepository),
        PortContract(name: "PersonRepository", file: "RepositoriesExtended.swift", expected: personRepository),
        PortContract(name: "RecordingRepository", file: "Repositories.swift", expected: recordingRepository),
        PortContract(name: "TranscriptRepository", file: "Repositories.swift", expected: transcriptRepository),
        PortContract(
            name: "SpeakerProfileRepository", file: "RepositoriesExtended.swift", expected: speakerProfileRepository
        ),
        PortContract(
            name: "ConnectorRepository", file: "RepositoriesExtended.swift", expected: connectorRepository
        ),
        PortContract(
            name: "MeetingOutputRepository", file: "RepositoriesExtended.swift", expected: meetingOutputRepository
        ),
        PortContract(
            name: "SettingsRepository", file: "RepositoriesExtended.swift", expected: settingsRepository
        ),
        PortContract(name: "JobHandler", file: "JobQueue.swift", expected: jobHandler),
        PortContract(name: "JobQueue", file: "JobQueue.swift", expected: jobQueue),
        PortContract(name: "JobRepository", file: "JobQueue.swift", expected: jobRepository),
        PortContract(name: "ModelCatalogPort", file: "ModelCatalogPort.swift", expected: modelCatalogPort),
        PortContract(name: "SessionCoordinator", file: "SessionCoordinator.swift", expected: sessionCoordinator),
        PortContract(name: "Scheduler", file: "SessionCoordinator.swift", expected: scheduler),
        PortContract(
            name: "ConnectorHostServices", file: "ConnectorHost.swift", expected: connectorHostServices
        ),
        PortContract(name: "CalendarConnector", file: "ConnectorHost.swift", expected: calendarConnector)
    ]
}
