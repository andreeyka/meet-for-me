//  CompositionRoot+Settings — снимок `AppSettings` при старте, разведено из
//  `CompositionRoot.swift` по объёму (`type_body_length`).
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: composition root

import DomainCore

extension CompositionRoot {

    /// Снимок `AppSettings` при старте — composition root читает `SettingsRepository`
    /// НАПРЯМУЮ, не через `AppFacade.settings()`: на шаге 6 (`build()`, `CompositionRoot+
    /// Steps.swift`) фасада ещё не существует (шаг 7, позже). Повторяет схему чтения
    /// `AppFacadeImpl.settings()` (C-016 §2.1 — ключ есть имя поля дословно) вместо вызова
    /// общей функции: `settingsField` приватна расширению `AppFacadeImpl+Settings.swift`, а
    /// заводить публичную обёртку в `domain-core` — за пределами этой задачи (composition
    /// root, `App/`). Известное небольшое дублирование, не случайное. `SessionMachine.
    /// settings` — `let`: применяется со следующего запуска приложения (MEE-433, решение РП
    /// п.3; живые настройки — IR-138, MEE-434, не блокирует).
    static func loadSettings(from repository: SettingsRepository) async throws -> AppSettings {
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

    static func field<Value: Codable>(
        _ type: Value.Type, _ key: String, _ defaultValue: Value, _ repository: SettingsRepository
    ) async throws -> Value {
        guard let data = try await repository.value(forKey: key) else { return defaultValue }
        guard let decoded = try? DomainJSON.decode(Value.self, from: data) else {
            throw CompositionRootError.settingsUnreadable(key: key)
        }
        return decoded
    }
}
