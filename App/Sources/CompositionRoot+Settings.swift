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

    /// Итог снимка настроек на старте — само значение и признак, откуда оно взято, для
    /// одноразового уведомления (IR-140, MEE-439). Собирает `loadSettings(from:)` и решение
    /// `startupSettingsFallback(for:)` в одно место, вызывающее стороне решать нечего.
    struct StartupSettingsResult: Equatable {
        let settings: AppSettings
        let usedDefaults: Bool
    }

    /// Снимок настроек на старте (IR-140, MEE-439, решение архитектора): сломанная строка
    /// (`CompositionRootError.settingsUnreadable`) здесь БОЛЬШЕ НЕ фатальна — composition
    /// root не вызывает `AppFacade.settings()` (её на этом шаге ещё нет), поэтому инвариант
    /// 28 контракта C-016 не затронут ни строкой: он про рантайм-поведение фасада, не про
    /// этот шаг. Любой другой отказ (каталог/БД/что угодно за пределами разбора настроек)
    /// пробрасывается как раньше — решение МЕЕ-430 §3 для «сломанного окружения» здесь не
    /// меняется, меняется только цена ИМЕННО нечитаемой строки настроек, у которой есть чем
    /// восстановиться (`AppSettings.slice1Defaults` — то же значение, что уже подставляет
    /// `settings()` на ПУСТОЙ строке).
    static func loadSettingsForStartup(from repository: SettingsRepository) async throws -> StartupSettingsResult {
        do {
            return StartupSettingsResult(settings: try await loadSettings(from: repository), usedDefaults: false)
        } catch {
            guard let fallback = startupSettingsFallback(for: error) else { throw error }
            return StartupSettingsResult(settings: fallback, usedDefaults: true)
        }
    }

    /// Чистая функция (без ввода-вывода, без `async`) — по этой причине тестируема отдельно
    /// от `SettingsRepository`. Отвечает только на ОДИН вопрос: эта ошибка — та самая
    /// восстановимая (`CompositionRootError.settingsUnreadable`), и если да, чем заменить?
    /// `nil` — «не эта ошибка, пробрасывай как была» (например,
    /// `applicationSupportDirectoryUnavailable` или отказ `StorageDatabase`/`SignalWeights`
    /// на более раннем шаге) — решение МЕЕ-430 §3 для них не тронуто ни строкой.
    ///
    /// Тест: `App/` не несёт тестового таргета (`project.yml` — файл архитектора, MEE-430;
    /// объявляет ровно два таргета, `MeetForMe`/`TranscriptionEngine`, ни одного тестового —
    /// сверено чтением файла целиком этой сессией). Завести его — правка `project.yml`, то
    /// есть interface-request, а не эта точечная задача (готовность IR-140 называет её явно
    /// «точечной правкой», не заводом инфраструктуры). Функция написана чистой намеренно,
    /// чтобы условие было проверяемо чтением тела без стенда, — раскрыто здесь, а не скрыто.
    static func startupSettingsFallback(for error: Error) -> AppSettings? {
        guard case CompositionRootError.settingsUnreadable = error else { return nil }
        return .slice1Defaults
    }
}
