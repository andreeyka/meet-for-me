//  MEE-289 (девять протоколов) + MEE-319 (ещё семь: пять портов C-010 §5,
//  `JobRepository` и `ModelCatalogPort` C-013): полнота и порядок объявлений против
//  разделов «Определение» их контрактов-владельцев, и имена полей `AppSettings` против
//  §2.1 C-016.
//
//  ПОЧЕМУ ЭТИ ПРОВЕРКИ, А НЕ ДРУГИЕ. Предмет MEE-289 — объявления, поведения в нём нет
//  ни строки, и тестов на поведение постановка запрещает прямо. Что остаётся проверяемым,
//  названо её §4: сборка, символьный граф и инварианты типов там, где их требует контракт.
//  Ни один из шести контрактов-владельцев (C-004, C-005, C-010, C-013, C-015, C-016, C-018)
//  не распространяет на свои типы `DomainValidatable` C-001 §0.2 — проверено прогоном по
//  каждому тексту целиком, вхождений ноль, — поэтому пути декодирования и почленного
//  инициализатора здесь проверять нечем: они синтезированы и зелены по построению.
//
//  Остаётся ровно то, что сборка НЕ ловит, и оно здесь:
//    1) недостача или лишнее требование в протоколе — форма прецедента MEE-86 (п. 153
//       перечня MEE-6, тест `ProtocolDeclarationTests`). Реализации у этих портов сегодня
//       нет ни одной, поэтому недостающий метод не краснит ни одну сборку;
//    2) порядок требований — перестановка множества не меняет, а контракт порядок задаёт;
//    3) имена и порядок полей `AppSettings`. Это не украшение: §2.1 C-016 говорит, что ключ
//       строки `app_settings` ЕСТЬ имя поля дословно, и «одно названное место, где
//       отображение живёт, — объявление `AppSettings`». Переименование поля молча меняет
//       ключ хранилища, и не ловит этого сегодня ничто. Проверяется `Mirror` по живому
//       значению, а не текстом: так проверяется скомпилированный тип, а не исходник.
//
//  ГРАНИЦА НАЗВАНА. Проверка текстовая: она доказывает, ЧТО объявлено, и не доказывает
//  ни одного ответа ни одной реализации — их не существует. Требование, закомментированное
//  в исходнике, требованием не считается (вектор ниже); требование, записанное иначе, чем
//  в контракте, покраснеет, даже если оно верно по смыслу, — это цена дословности, и она
//  принята: расхождение читается на приёмке за один взгляд.

import Foundation
import XCTest
import DomainCore

final class PortDeclarationTests: XCTestCase {

    // MARK: - Ожидания: блоки контрактов дословно, в их порядке

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

    static let jobQueue = [
        "func register(handler: JobHandler) async throws",
        "func submit(_ submission: JobSubmission) async throws -> UUID",
        "func cancel(jobId: UUID) async throws",
        "func job(id: UUID) async throws -> Job?",
        "func jobs(status: JobStatus) async throws -> [Job]",
        "func start() async",
        "func stop() async",
        "func events() -> AsyncStream<JobEvent>"
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

    /// C-013 (MEE-21) §1.1 — дописан MEE-319. Единственный метод, что C-013 даёт
    /// дословно; развилка по остальному объёму порта — комментарий над объявлением
    /// в `JobQueue.swift` (`// СТРОКА:`).
    static let modelCatalogPort = [
        "func missingModels(profileId: String) async throws -> [String]"
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
        PortContract(name: "ModelCatalogPort", file: "JobQueue.swift", expected: modelCatalogPort),
        PortContract(name: "SessionCoordinator", file: "SessionCoordinator.swift", expected: sessionCoordinator),
        PortContract(name: "Scheduler", file: "SessionCoordinator.swift", expected: scheduler)
    ]

    // MARK: - Состав

    /// Ни одним требованием меньше и ни одним больше: поверхность, которой контракт
    /// не обещал, — то же нарушение П2, что и недостача.
    func test_mee289_everyPortDeclaresExactlyTheRequirementsOfItsContract() throws {
        for contract in Self.contracts {
            let declared = try Self.requirements(ofProtocol: contract.name, inFile: contract.file)
            XCTAssertEqual(Set(declared), Set(contract.expected),
                           "множество требований \(contract.name) разошлось с его контрактом")
        }
    }

    // MARK: - Порядок

    /// Порядок задан контрактом и здесь проверяется отдельно от состава: перестановка
    /// двух требований множества не меняет, и первая проверка её пропускает.
    func test_mee289_everyPortKeepsTheOrderOfItsContract() throws {
        for contract in Self.contracts {
            let declared = try Self.requirements(ofProtocol: contract.name, inFile: contract.file)
            XCTAssertEqual(declared, contract.expected,
                           "порядок требований \(contract.name) разошёлся с его контрактом")
        }
    }

    // MARK: - Исходник действительно прочитан

    /// Без этого обе проверки выше зелены на пустой строке: пустое множество равно пустому.
    func test_mee289_sourcesAreActuallyRead() throws {
        for contract in Self.contracts {
            let declared = try Self.requirements(ofProtocol: contract.name, inFile: contract.file)
            XCTAssertFalse(declared.isEmpty, "блок \(contract.name) прочитан пустым")
        }
    }

    // MARK: - Область разбора: комментарий требованием не является

    /// Закомментированное требование не считается. Образец, а не сегодняшний файл:
    /// проверяется само исключение, а не дерево, на котором оно сегодня ни на чём не сказывается.
    func test_mee289_commentedRequirementIsNotCounted() {
        let sample = """
        public protocol Scheduler: Sendable {
            // func plan(now: Date) async throws -> [ScheduledArm]
            func stop() async   // хвостовой комментарий тоже не часть требования
        }
        """
        XCTAssertEqual(Self.requirements(in: sample, protocolNamed: "Scheduler"), ["func stop() async"])
    }

    /// Обратная половина: за закрывающей скобкой блока область кончается.
    func test_mee289_parsingStopsAtClosingBrace() {
        let sample = """
        public protocol Scheduler: Sendable {
            func stop() async
        }

        public protocol Другой: Sendable {
            func plan(now: Date) async throws -> [ScheduledArm]
        }
        """
        XCTAssertEqual(Self.requirements(in: sample, protocolNamed: "Scheduler"), ["func stop() async"])
    }

    /// Требование, разнесённое по строкам, склеивается в одно: так объявлен `JobHandler.run`.
    func test_mee289_wrappedRequirementIsOneRequirement() {
        let sample = """
        public protocol JobHandler: Sendable {
            var type: JobType { get }
            func run(_ job: Job,
                     progress: @Sendable @escaping (Double) -> Void) async -> JobOutcome
        }
        """
        XCTAssertEqual(Self.requirements(in: sample, protocolNamed: "JobHandler"), Self.jobHandler)
    }

    // MARK: - §2.1 C-016: ключи `app_settings` суть имена полей `AppSettings`

    /// Имена и порядок полей проверяются по живому значению, а не по исходнику: §2.1
    /// объявляет отображение правилом, и его единственное место — это объявление.
    /// Переименование поля здесь молча сменило бы ключ строки `app_settings`.
    func test_mee289_appSettingsFieldNamesAreTheStorageKeys() throws {
        let expected = [
            "recordingPolicy",
            "armLeadSeconds",
            "askLeadSeconds",
            "missingSignalGraceSeconds",
            "silenceStopSeconds",
            "defaultProfileId",
            "processOnACPowerOnly",
            "processWhileRecording",
            "audioRetentionDays",
            "voiceProfilesEnabled",
            "notifyParticipants",
            "launchAtLogin"
        ]
        let settings = AppSettings(
            recordingPolicy: .ask,
            armLeadSeconds: 120,
            askLeadSeconds: 30,
            missingSignalGraceSeconds: 900,
            silenceStopSeconds: 300,
            defaultProfileId: "профиль-вектора",
            processOnACPowerOnly: true,
            processWhileRecording: false,
            audioRetentionDays: nil,
            voiceProfilesEnabled: true,
            notifyParticipants: false,
            launchAtLogin: true
        )
        // Замыкание, а не ключевой путь: `Mirror.Child` — кортеж, а ключевых путей
        // к элементам кортежа Swift 5.9 не имеет, и `\.label` здесь не собралось бы.
        let declared = Mirror(reflecting: settings).children.compactMap { $0.label }
        XCTAssertEqual(declared, expected, "имена или порядок полей AppSettings разошлись с §2 C-016")
    }

    // MARK: - Оснастка

    private static func requirements(ofProtocol name: String, inFile file: String) throws -> [String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/DomainCore/\(file)")
        let text = try String(contentsOf: url, encoding: .utf8)
        return requirements(in: text, protocolNamed: name)
    }

    /// Тело блока протокола: строки без комментариев и без пустых, склеенные по требованиям.
    /// Требование начинается со своего ключевого слова; всё прочее — продолжение предыдущего.
    static func requirements(in text: String, protocolNamed name: String) -> [String] {
        let header = "public protocol \(name): Sendable {"
        var inside = false
        var depth = 0
        var found: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            if !inside {
                guard rawLine.contains(header) else { continue }
                inside = true
                depth = braceBalance(of: rawLine)
                continue
            }
            depth += braceBalance(of: rawLine)
            if depth <= 0 { break }
            let line = withoutComment(rawLine)
            guard !line.isEmpty else { continue }
            if startsRequirement(line) {
                found.append(line)
            } else if !found.isEmpty {
                found[found.count - 1] += " " + line
            }
        }
        return found
    }

    /// Хвостовой комментарий отрезается вместе со строкой-комментарием: и тот и другой
    /// требованием не являются, а различать их здесь нечем и незачем.
    private static func withoutComment(_ line: String) -> String {
        let body = line.components(separatedBy: "//").first ?? ""
        return body.trimmingCharacters(in: .whitespaces)
    }

    private static func startsRequirement(_ line: String) -> Bool {
        ["func ", "var ", "static ", "init", "associatedtype ", "subscript"]
            .contains { line.hasPrefix($0) }
    }

    /// Баланс скобок строки. `{ get }` в требовании-свойстве сходится сам с собой и
    /// глубину блока не сдвигает — потому она и считается по строке, а не по символу.
    private static func braceBalance(of line: String) -> Int {
        line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
    }
}
