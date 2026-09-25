//  FakeAppFacade — методы-команды. Разведено в отдельный файл по объёму
//  (`type_body_length`), не по смыслу — см. заголовок `FakeAppFacade.swift`.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен (фейки портов для тестов)
//
//  Каждый метод: записывает вызов (`record`), затем бросает `forcedError`, если он
//  задан, иначе отдаёт настроенный результат. Ни один инвариант C-016 не проверяется —
//  фейк не эталон поведения фасада, поведение целиком задаёт тест.

import Foundation
import DomainCore

extension FakeAppFacade {

    // MARK: - Команды записи

    public func startRecording(meetingId: UUID?) async throws -> UUID {
        record("startRecording(meetingId:)", [meetingId?.uuidString ?? "nil"])
        if let forcedError { throw forcedError }
        return startRecordingResult
    }

    public func stopRecording(recordingId: UUID) async throws {
        record("stopRecording(recordingId:)", [recordingId.uuidString])
        if let forcedError { throw forcedError }
    }

    public func skipMeeting(meetingId: UUID) async throws {
        record("skipMeeting(meetingId:)", [meetingId.uuidString])
        if let forcedError { throw forcedError }
    }

    // MARK: - Команды календаря и прав

    public func syncCalendars() async -> [CalendarSyncResult] {
        record("syncCalendars()", [])
        return syncCalendarsResult
    }

    public func setConnectorEnabled(_ enabled: Bool, sourceId: CalendarSourceId) async throws {
        record("setConnectorEnabled(_:sourceId:)", [String(enabled), sourceId.rawValue])
        if let forcedError { throw forcedError }
    }

    public func beginConnectorAuth(sourceId: CalendarSourceId) async throws -> AuthChallenge {
        record("beginConnectorAuth(sourceId:)", [sourceId.rawValue])
        if let forcedError { throw forcedError }
        return beginConnectorAuthResult
    }

    public func completeConnectorAuth(sourceId: CalendarSourceId, callbackUrl: URL) async throws -> String? {
        record("completeConnectorAuth(sourceId:callbackUrl:)", [sourceId.rawValue, callbackUrl.absoluteString])
        if let forcedError { throw forcedError }
        return completeConnectorAuthResult
    }

    public func connectorSettingsSchema(sourceId: CalendarSourceId) async throws -> Data {
        record("connectorSettingsSchema(sourceId:)", [sourceId.rawValue])
        if let forcedError { throw forcedError }
        return connectorSettingsSchemaResult
    }

    public func configureConnector(sourceId: CalendarSourceId, settings: Data) async throws {
        record("configureConnector(sourceId:settings:)", [sourceId.rawValue, settings.base64EncodedString()])
        if let forcedError { throw forcedError }
    }

    public func connectorHealth(sourceId: CalendarSourceId) async throws -> ConnectorHealthView {
        record("connectorHealth(sourceId:)", [sourceId.rawValue])
        if let forcedError { throw forcedError }
        let template = connectorHealthTemplate
        return ConnectorHealthView(
            sourceId: sourceId, displayName: template.displayName, isEnabled: template.isEnabled,
            status: template.status, message: template.message, lastSyncAt: template.lastSyncAt,
            needsAuthorization: template.needsAuthorization
        )
    }

    public func requestPermission(_ kind: PermissionKind) async -> PermissionRequestOutcome {
        record("requestPermission(_:)", [kind.rawValue])
        return requestPermissionResult
    }

    public func openPermissionSettings(_ kind: PermissionKind) async throws {
        record("openPermissionSettings(_:)", [kind.rawValue])
        if let forcedError { throw forcedError }
    }

    // MARK: - Команды моделей и профилей

    public func downloadModel(id: String, version: String) async throws {
        record("downloadModel(id:version:)", [id, version])
        if let forcedError { throw forcedError }
    }

    public func cancelModelDownload(id: String, version: String) async {
        record("cancelModelDownload(id:version:)", [id, version])
    }

    public func deleteModel(id: String, version: String) async throws {
        record("deleteModel(id:version:)", [id, version])
        if let forcedError { throw forcedError }
    }

    public func saveProfile(_ profile: TranscriptionProfile) async throws {
        record("saveProfile(_:)", [String(describing: profile)])
        if let forcedError { throw forcedError }
    }

    public func deleteProfile(id: String) async throws {
        record("deleteProfile(id:)", [id])
        if let forcedError { throw forcedError }
    }

    // MARK: - Команды обработки

    public func retranscribe(recordingId: UUID, profileId: String) async throws -> UUID {
        record("retranscribe(recordingId:profileId:)", [recordingId.uuidString, profileId])
        if let forcedError { throw forcedError }
        return retranscribeResult
    }

    public func cancelJob(id: UUID) async throws {
        record("cancelJob(id:)", [id.uuidString])
        if let forcedError { throw forcedError }
    }

    public func retryJob(id: UUID) async throws -> UUID {
        record("retryJob(id:)", [id.uuidString])
        if let forcedError { throw forcedError }
        return retryJobResult
    }

    // MARK: - Команды правки транскрипта

    public func assignSpeaker(transcriptId: UUID, cluster: Int, personId: UUID) async throws {
        record(
            "assignSpeaker(transcriptId:cluster:personId:)",
            [transcriptId.uuidString, String(cluster), personId.uuidString]
        )
        if let forcedError { throw forcedError }
    }

    public func createPersonAndAssign(
        transcriptId: UUID, cluster: Int, displayName: String, email: String?
    ) async throws -> UUID {
        record(
            "createPersonAndAssign(transcriptId:cluster:displayName:email:)",
            [transcriptId.uuidString, String(cluster), displayName, email ?? "nil"]
        )
        if let forcedError { throw forcedError }
        return createPersonAndAssignResult
    }

    public func clearSpeaker(transcriptId: UUID, cluster: Int) async throws {
        record("clearSpeaker(transcriptId:cluster:)", [transcriptId.uuidString, String(cluster)])
        if let forcedError { throw forcedError }
    }

    public func editSegmentText(segmentId: Int64, text: String) async throws {
        record("editSegmentText(segmentId:text:)", [String(segmentId), text])
        if let forcedError { throw forcedError }
    }

    public func renamePerson(personId: UUID, displayName: String) async throws {
        record("renamePerson(personId:displayName:)", [personId.uuidString, displayName])
        if let forcedError { throw forcedError }
    }

    public func forgetVoiceProfile(personId: UUID) async throws {
        record("forgetVoiceProfile(personId:)", [personId.uuidString])
        if let forcedError { throw forcedError }
    }

    // MARK: - Хранение и экспорт

    public func deleteRecording(recordingId: UUID, deleteFiles: Bool) async throws {
        record("deleteRecording(recordingId:deleteFiles:)", [recordingId.uuidString, String(deleteFiles)])
        if let forcedError { throw forcedError }
    }

    public func deleteMeeting(meetingId: UUID) async throws {
        record("deleteMeeting(meetingId:)", [meetingId.uuidString])
        if let forcedError { throw forcedError }
    }

    public func export(meetingId: UUID, format: ExportFormat, to directory: URL) async throws -> URL {
        record("export(meetingId:format:to:)", [meetingId.uuidString, format.rawValue, directory.absoluteString])
        if let forcedError { throw forcedError }
        return exportResult
    }

    // MARK: - Настройки

    public func updateSettings(_ settings: AppSettings) async throws {
        record("updateSettings(_:)", [String(describing: settings)])
        if let forcedError { throw forcedError }
        settingsValue = settings
    }
}
