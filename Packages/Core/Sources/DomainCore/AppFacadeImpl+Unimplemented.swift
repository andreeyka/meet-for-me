//  AppFacadeImpl — команды, не реализованные этим срезом MEE-420 части 5. См. заголовок
//  `AppFacadeImpl.swift`: каждая ждёт своего PR по группе плана MEE-410, названной в
//  сообщении отказа. Разведено в отдельный файл, чтобы группа, чья реализация появится
//  следующей, меняла один метод в одном файле, не трогая остальные. Группа В (К10-К12,
//  startRecording/stopRecording) реализована — см. `AppFacadeImpl+Recording.swift` (там же —
//  `skipMeeting`, группа Х, MEE-441). Группа Г (К13-К14, editSegmentText) реализована — см.
//  `AppFacadeImpl.swift`. Группы Д и Е (assignSpeaker/clearSpeaker/createPersonAndAssign/
//  forgetVoiceProfile, К15-К20, К50-К52) реализованы — см. `AppFacadeImpl+Attribution.swift`.
//  Группа Ж (settings()/updateSettings()) реализована параллельно, отдельным PR — см.
//  `AppFacadeImpl+Settings.swift` (MEE-425). Группа О (К39-К40, календарь и коннекторы) —
//  `AppFacadeImpl+Calendar.swift` (MEE-441). Группа П (К41, хранение и экспорт) —
//  `AppFacadeImpl+StorageExport.swift` (MEE-441). Группа Ф (К46, renamePerson) —
//  `AppFacadeImpl+RenamePerson.swift` (MEE-441).
//
//  Остаются группы М (модели и профили) и Н (команды обработки) — «группы М-Х не трогать»
//  (РП, MEE-441) не относится к их уже сделанным соседям выше, только к этим двум.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import Foundation

extension AppFacadeImpl {

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
}
