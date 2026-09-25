//  AppFacade — контракт C-016 v9 (MEE-25), «Определение», §3 (события и ошибки), §4
//  (протокол). MEE-420, слой 1 плана MEE-410. §1 (модели чтения) — в соседнем файле
//  `AppFacadeReadModels.swift`, разведено по объёму, не по смыслу (`file_length`).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  `AppSettings` (§2) объявлен отдельным файлом раньше (MEE-289, `AppSettings.swift`) —
//  не повторяется здесь. `AppSettings.slice1Defaults` там же не объявлен и остаётся не
//  объявленным: семи из двенадцати полей контракт не называет значения по умолчанию —
//  находка сообщена архитектору тем файлом, эта задача её не решает и не изобретает
//  значения сама.
//
//  ПОРЯДОК ТИПОВ И ПОРЯДОК ПОЛЕЙ ВНУТРИ ТИПА — дословно по §1/§3/§4 контракта (порядок
//  значим: правило обхода C-001 §0.2 п. 9 обходит поля в порядке объявления).
//
//  ТОЛЬКО ОБЪЯВЛЕНИЯ. Реализацию фасада пишет `domain-core` отдельной задачей (группы
//  Б–Ц плана MEE-410) — этот файл не задаёт ни одного метода телом.

import Foundation

// MARK: - §2 (продолжение). Экспорт

public enum ExportFormat: String, Codable, Sendable {
    case markdown, json, srt, vtt, bundle
}

// MARK: - §3. События и ошибки

public struct AppErrorView: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
    public let recoverySuggestion: String?
    public let permissionKind: PermissionKind?

    public init(code: String, message: String, recoverySuggestion: String?, permissionKind: PermissionKind?) {
        self.code = code
        self.message = message
        self.recoverySuggestion = recoverySuggestion
        self.permissionKind = permissionKind
    }
}

public enum AppEvent: Equatable, Sendable {
    case statusChanged(AppStatus)
    case meetingsChanged
    case transcriptChanged(transcriptId: UUID)
    case jobProgressed(jobId: UUID, type: JobType, fraction: Double)
    case permissionsChanged(PermissionSnapshot)
    case modelsChanged
    case settingsChanged(AppSettings)
    case failure(AppErrorView)
}

public enum AppFacadeError: Error, Codable, Equatable, Sendable {
    case notFound(entity: String, id: String)
    case notAllowed(reason: String)
    case permissionRequired(PermissionKind)
    case profileNotReady(profileId: String, missingModelIds: [String])
    case settingsUnreadable(key: String)
    case underlying(AppErrorView)
}

// MARK: - §4. Протокол

public protocol AppFacade: Sendable {

    // --- Чтение ---
    func status() async -> AppStatus
    func meetings(from: Date, to: Date) async throws -> [MeetingListItem]
    func meeting(id: UUID) async throws -> MeetingDetail?
    func transcript(id: UUID) async throws -> TranscriptView?
    func latestTranscript(recordingId: UUID) async throws -> TranscriptView?
    func search(query: String, limit: Int, offset: Int) async throws -> [SearchHit]
    func permissions() async -> PermissionSnapshot
    func models() async -> [ModelDescriptor]
    func modelState(id: String, version: String) async -> ModelState
    func profiles() async -> [TranscriptionProfile]
    func jobs(status: JobStatus) async throws -> [Job]
    func settings() async throws -> AppSettings

    // --- Команды записи ---
    func startRecording(meetingId: UUID?) async throws -> UUID
    func stopRecording(recordingId: UUID) async throws
    func skipMeeting(meetingId: UUID) async throws

    // --- Команды календаря и прав ---
    func syncCalendars() async -> [CalendarSyncResult]
    func setConnectorEnabled(_ enabled: Bool, sourceId: CalendarSourceId) async throws
    func beginConnectorAuth(sourceId: CalendarSourceId) async throws -> AuthChallenge
    func completeConnectorAuth(sourceId: CalendarSourceId, callbackUrl: URL) async throws -> String?
    func connectorSettingsSchema(sourceId: CalendarSourceId) async throws -> Data
    func configureConnector(sourceId: CalendarSourceId, settings: Data) async throws
    func connectorHealth(sourceId: CalendarSourceId) async throws -> ConnectorHealthView
    func requestPermission(_ kind: PermissionKind) async -> PermissionRequestOutcome
    func openPermissionSettings(_ kind: PermissionKind) async throws

    // --- Команды моделей и профилей ---
    func downloadModel(id: String, version: String) async throws
    func cancelModelDownload(id: String, version: String) async
    func deleteModel(id: String, version: String) async throws
    func saveProfile(_ profile: TranscriptionProfile) async throws
    func deleteProfile(id: String) async throws

    // --- Команды обработки ---
    func retranscribe(recordingId: UUID, profileId: String) async throws -> UUID
    func cancelJob(id: UUID) async throws
    func retryJob(id: UUID) async throws -> UUID

    // --- Команды правки транскрипта ---
    func assignSpeaker(transcriptId: UUID, cluster: Int, personId: UUID) async throws
    func createPersonAndAssign(
        transcriptId: UUID, cluster: Int, displayName: String, email: String?
    ) async throws -> UUID
    func clearSpeaker(transcriptId: UUID, cluster: Int) async throws
    func editSegmentText(segmentId: Int64, text: String) async throws
    func renamePerson(personId: UUID, displayName: String) async throws
    func forgetVoiceProfile(personId: UUID) async throws

    // --- Хранение и экспорт ---
    func deleteRecording(recordingId: UUID, deleteFiles: Bool) async throws
    func deleteMeeting(meetingId: UUID) async throws
    func export(meetingId: UUID, format: ExportFormat, to directory: URL) async throws -> URL

    // --- Настройки и поток изменений ---
    func updateSettings(_ settings: AppSettings) async throws
    func events() -> AsyncStream<AppEvent>
}
