//  FakeAppFacade — реализация `AppFacade` (C-016) поверх заданного тестом состояния.
//  C-016 §«Фейк для тестов», MEE-420 (слой 2 плана MEE-410).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  СОСТАВ — §«Фейк для тестов» C-016 дословно: «реализация AppFacade поверх заданного
//  тестом состояния... Умеет: заставить любую команду бросить любую AppFacadeError;
//  записать все вызванные команды с аргументами и отдать их тесту списком; вручную
//  протолкнуть любой AppEvent, включая failure с любым AppErrorView».
//
//  ПРЕДМЕТ ЭТОГО ФЕЙКА — ОН САМ, НЕ РЕАЛИЗАЦИЯ ФАСАДА (план MEE-410, §0, правка РП п.1):
//  40 из 47 поведенческих критериев плана проверяют настоящую реализацию AppFacade на
//  прямых фейках портов/репозиториев, когда она появится (группы Б–Ц), а не этот фейк.
//  `FakeAppFacade` служит только К44 (собственное существование/умения) и половине К49
//  (`app-ui` реагирует на события фейка) — оба вне Core, кроме К44.
//
//  ЕДИНАЯ ОШИБКА НА ВСЕ КОМАНДЫ, А НЕ СЛОВАРЬ ПО МЕТОДАМ: контракт называет условие
//  «заставить любую команду бросить любую AppFacadeError» без слова «одновременно» или
//  «разные ошибки разным методам» — сценарий теста ставит фасад в одно отказное
//  состояние зараз, тем же приёмом, каким `forcedError` устроен у более простых фейков
//  этого пакета (`FakeAttributionPort` и подобные).
//
//  Значения чтения (`AppStatus`, `PermissionSnapshot`, `AppSettings`) обязательны при
//  создании: `AppSettings.slice1Defaults` не объявлен (см. `AppSettings.swift`), фейку
//  неоткуда взять их сам, и он не имеет права изобретать их — состояние целиком задаёт тест.
//
//  Разведён на этот файл (состояние, чтение, события) и `FakeAppFacade+Commands.swift`
//  (все методы-команды) — по объёму (`type_body_length`/`file_length`), не по смыслу,
//  тем же приёмом, что `GRDBMeetingRepositoryWrite.swift`/`InMemoryTranscriptRepositoryCorrections.swift`.

import Foundation
import DomainCore

/// Один вызов команды фасада — имя метода и аргументы текстом, в порядке подписи.
public struct FakeAppFacadeCommand: Equatable, Sendable {
    public let name: String
    public let arguments: [String]

    public init(name: String, arguments: [String]) {
        self.name = name
        self.arguments = arguments
    }
}

/// Поля `ConnectorHealthView`, которые не зависят от `sourceId` параметра вызова —
/// `connectorHealth(sourceId:)` собирает из них ответ вместе с переданным `sourceId`.
public struct ConnectorHealthTemplate: Equatable, Sendable {
    public var displayName = "Calendar"
    public var isEnabled = true
    public var status = ConnectorHealth.Status.ok
    public var message: String?
    public var lastSyncAt: Date?
    public var needsAuthorization = false

    public init() {}
}

/// Фейк `AppFacade`. Всё поведение задаёт тест.
public final class FakeAppFacade: AppFacade, @unchecked Sendable {

    let lock = NSLock()

    // MARK: - Состояние чтения (задаётся тестом)

    public var statusValue: AppStatus
    public var meetingsValue: [MeetingListItem] = []
    public var meetingDetailValue: MeetingDetail?
    public var transcriptValue: TranscriptView?
    public var latestTranscriptValue: TranscriptView?
    public var searchHitsValue: [SearchHit] = []
    public var permissionSnapshotValue: PermissionSnapshot
    public var modelsValue: [ModelDescriptor] = []
    public var modelStateValue: ModelState = .available
    public var profilesValue: [TranscriptionProfile] = []
    public var jobsValue: [Job] = []
    public var settingsValue: AppSettings

    // MARK: - Возвращаемые значения команд (задаются тестом, разумные значения по умолчанию)

    var startRecordingResult = UUID()
    var syncCalendarsResult: [CalendarSyncResult] = []
    var beginConnectorAuthResult = AuthChallenge(
        authUrl: URL(string: "https://example.com/oauth")!, redirectScheme: "meetforme"
    )
    var completeConnectorAuthResult: String?
    var connectorSettingsSchemaResult = Data()
    var connectorHealthTemplate = ConnectorHealthTemplate()
    var requestPermissionResult: PermissionRequestOutcome = .granted
    var retranscribeResult = UUID()
    var retryJobResult = UUID()
    var createPersonAndAssignResult = UUID()
    var exportResult = URL(fileURLWithPath: "/tmp/export")

    // MARK: - Управление из теста

    /// Заставить любую команду бросить эту ошибку; `nil` снимает отказ.
    public var forcedError: AppFacadeError?

    var recordedCommandsStorage: [FakeAppFacadeCommand] = []
    var continuations: [AsyncStream<AppEvent>.Continuation] = []

    public init(status: AppStatus, permissions: PermissionSnapshot, settings: AppSettings) {
        self.statusValue = status
        self.permissionSnapshotValue = permissions
        self.settingsValue = settings
    }

    func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Все вызванные команды в порядке вызова. Чтения (`status`, `meetings`, …) сюда не
    /// попадают — контракт называет именно «команды».
    public var recordedCommands: [FakeAppFacadeCommand] {
        locked { recordedCommandsStorage }
    }

    func record(_ name: String, _ arguments: [String]) {
        locked { recordedCommandsStorage.append(FakeAppFacadeCommand(name: name, arguments: arguments)) }
    }

    /// Протолкнуть событие в поток. Значение не приводится ни к чему и доходит как есть —
    /// включая `.failure` с произвольным `AppErrorView`, вплоть до `code == "app.internalError"`.
    public func push(_ event: AppEvent) {
        let targets = locked { continuations }
        for continuation in targets {
            continuation.yield(event)
        }
    }

    /// Закрыть поток: подписчики досматривают выданное и выходят из цикла.
    public func finishEvents() {
        let targets = locked { () -> [AsyncStream<AppEvent>.Continuation] in
            let taken = continuations
            continuations = []
            return taken
        }
        for continuation in targets {
            continuation.finish()
        }
    }

    // MARK: - AppFacade: чтение

    public func status() async -> AppStatus { statusValue }
    public func meetings(from: Date, to: Date) async throws -> [MeetingListItem] {
        if let forcedError { throw forcedError }
        return meetingsValue
    }
    public func meeting(id: UUID) async throws -> MeetingDetail? {
        if let forcedError { throw forcedError }
        return meetingDetailValue
    }
    public func transcript(id: UUID) async throws -> TranscriptView? {
        if let forcedError { throw forcedError }
        return transcriptValue
    }
    public func latestTranscript(recordingId: UUID) async throws -> TranscriptView? {
        if let forcedError { throw forcedError }
        return latestTranscriptValue
    }
    public func search(query: String, limit: Int, offset: Int) async throws -> [SearchHit] {
        if let forcedError { throw forcedError }
        return searchHitsValue
    }
    public func permissions() async -> PermissionSnapshot { permissionSnapshotValue }
    public func models() async -> [ModelDescriptor] { modelsValue }
    public func modelState(id: String, version: String) async -> ModelState { modelStateValue }
    public func profiles() async -> [TranscriptionProfile] { profilesValue }
    public func jobs(status: JobStatus) async throws -> [Job] {
        if let forcedError { throw forcedError }
        return jobsValue
    }
    public func settings() async throws -> AppSettings {
        if let forcedError { throw forcedError }
        return settingsValue
    }

    public func events() -> AsyncStream<AppEvent> {
        AsyncStream { continuation in
            locked { continuations.append(continuation) }
        }
    }
}
