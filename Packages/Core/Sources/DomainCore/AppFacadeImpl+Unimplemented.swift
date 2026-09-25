//  AppFacadeImpl — команды, не реализованные этим срезом MEE-420 части 4. См. заголовок
//  `AppFacadeImpl.swift`: каждая ждёт своего PR по группе плана MEE-410, названной в
//  сообщении отказа. Разведено в отдельный файл, чтобы группа, чья реализация появится
//  следующей, меняла один метод в одном файле, не трогая остальные. Группа В (К10-К12,
//  startRecording/stopRecording) реализована — см. `AppFacadeImpl+Recording.swift`. Группа Г
//  (К13-К14, editSegmentText) реализована — см. `AppFacadeImpl.swift`. Группа Ж (К21-К24,
//  settings()/updateSettings()) реализована — см. `AppFacadeImpl+Settings.swift` (MEE-425).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

extension AppFacadeImpl {

    // MARK: - Команды записи (группа Х плана — skipMeeting, соседи startRecording/stopRecording уже реализованы)

    public func skipMeeting(meetingId: UUID) async throws {
        throw notImplemented("skipMeeting(meetingId:)", group: "Х (skipMeeting и соседи)")
    }

    // MARK: - Команды календаря и коннекторов (группа О)

    public func setConnectorEnabled(_ enabled: Bool, sourceId: CalendarSourceId) async throws {
        throw notImplemented("setConnectorEnabled(_:sourceId:)", group: "О (календарь и коннекторы)")
    }

    public func beginConnectorAuth(sourceId: CalendarSourceId) async throws -> AuthChallenge {
        throw notImplemented("beginConnectorAuth(sourceId:)", group: "О (календарь и коннекторы)")
    }

    public func completeConnectorAuth(sourceId: CalendarSourceId, callbackUrl: URL) async throws -> String? {
        throw notImplemented("completeConnectorAuth(sourceId:callbackUrl:)", group: "О (календарь и коннекторы)")
    }

    public func connectorSettingsSchema(sourceId: CalendarSourceId) async throws -> Data {
        throw notImplemented("connectorSettingsSchema(sourceId:)", group: "О (календарь и коннекторы)")
    }

    public func configureConnector(sourceId: CalendarSourceId, settings: Data) async throws {
        throw notImplemented("configureConnector(sourceId:settings:)", group: "О (календарь и коннекторы)")
    }

    public func connectorHealth(sourceId: CalendarSourceId) async throws -> ConnectorHealthView {
        throw notImplemented("connectorHealth(sourceId:)", group: "О (календарь и коннекторы)")
    }

    // MARK: - Команды моделей и профилей (группа М)

    public func downloadModel(id: String, version: String) async throws {
        throw notImplemented("downloadModel(id:version:)", group: "М (модели и профили)")
    }

    public func deleteModel(id: String, version: String) async throws {
        throw notImplemented("deleteModel(id:version:)", group: "М (модели и профили)")
    }

    public func saveProfile(_ profile: TranscriptionProfile) async throws {
        throw notImplemented("saveProfile(_:)", group: "М (модели и профили)")
    }

    public func deleteProfile(id: String) async throws {
        throw notImplemented("deleteProfile(id:)", group: "М (модели и профили)")
    }

    // MARK: - Команды обработки (группа Н)

    public func retranscribe(recordingId: UUID, profileId: String) async throws -> UUID {
        throw notImplemented("retranscribe(recordingId:profileId:)", group: "Н (команды обработки)")
    }

    public func cancelJob(id: UUID) async throws {
        throw notImplemented("cancelJob(id:)", group: "Н (команды обработки)")
    }

    public func retryJob(id: UUID) async throws -> UUID {
        throw notImplemented("retryJob(id:)", group: "Н (команды обработки)")
    }

    // MARK: - Команды правки транскрипта (группы Д, Е, Ф — Г реализована, см. AppFacadeImpl.swift)

    public func assignSpeaker(transcriptId: UUID, cluster: Int, personId: UUID) async throws {
        throw notImplemented("assignSpeaker(transcriptId:cluster:personId:)", group: "Д (правка спикеров)")
    }

    public func createPersonAndAssign(
        transcriptId: UUID, cluster: Int, displayName: String, email: String?
    ) async throws -> UUID {
        throw notImplemented(
            "createPersonAndAssign(transcriptId:cluster:displayName:email:)", group: "Д (правка спикеров)"
        )
    }

    public func clearSpeaker(transcriptId: UUID, cluster: Int) async throws {
        throw notImplemented("clearSpeaker(transcriptId:cluster:)", group: "Д (правка спикеров)")
    }

    public func renamePerson(personId: UUID, displayName: String) async throws {
        throw notImplemented("renamePerson(personId:displayName:)", group: "Ф (renamePerson)")
    }

    public func forgetVoiceProfile(personId: UUID) async throws {
        throw notImplemented("forgetVoiceProfile(personId:)", group: "Е (forgetVoiceProfile)")
    }

    // MARK: - Хранение и экспорт (группа П)

    public func deleteRecording(recordingId: UUID, deleteFiles: Bool) async throws {
        throw notImplemented("deleteRecording(recordingId:deleteFiles:)", group: "П (хранение и экспорт)")
    }

    public func deleteMeeting(meetingId: UUID) async throws {
        throw notImplemented("deleteMeeting(meetingId:)", group: "П (хранение и экспорт)")
    }

    public func export(meetingId: UUID, format: ExportFormat, to directory: URL) async throws -> URL {
        throw notImplemented("export(meetingId:format:to:)", group: "П (хранение и экспорт)")
    }
}
