//  AppFacadeImpl — настройки (C-016 v10, §2/§2.1, инв. 18/28), группа Ж плана MEE-410
//  (К21-К24). MEE-425 — в помощь MEE-420, отдельный PR от main. `AppSettings.slice1Defaults`
//  объявлен (`AppSettings.swift`, IR-105 закрыт C-016 v10).
//
//  Модуль: domain-core · Владелец: DEV-1 (в помощь MEE-420) · Слой: домен
//
//  ОТОБРАЖЕНИЕ КЛЮЧ↔ПОЛЕ — ЗДЕСЬ, ОДНИМ МЕСТОМ, ДВАЖДЫ (§2.1: «правило выводит состав
//  ключей из объявления… одно названное место — объявление AppSettings в §2»). Список
//  двенадцати ключей не выписан отдельной таблицей нигде — он есть аргументы вызова
//  `AppSettings.init` в `settings()` и `settingsEntries(for:)` в `updateSettings(_:)`.
//
//  Возврат РП (MEE-425, комментарий `4d1d45a5`): компилятор здесь проверяет не всё —
//  добавление, переименование или смена ТИПА поля `AppSettings.init` действительно не
//  пройдёт компиляцию ни здесь, ни там (значения передаются доступом к самому полю,
//  `settings.recordingPolicy`, а не строкой). Но СТРОКА `key:` — обычный `String`-литерал,
//  и одинаковая опечатка в обоих местах (например, `"launchOnLogin"` вместо
//  `"launchAtLogin"`) компилируется чисто и молча расходится с C-013/C-015, которые читают
//  ключи напрямую, строкой. Эту половину проверяет не компилятор, а тест К23
//  (`SettingsTests.swift`) — сверкой множества записанных ключей с `Mirror(reflecting:
//  settings).children`, а не переписыванием того же перечня третий раз.
//
//  ПОРЯДОК КЛЮЧЕЙ В `settingsEntries(for:)` — порядок полей `AppSettings.init` (§2, дословно).
//  Значим для К24 (атомарность на «третьем по порядку ключе» — сам порядок должен что-то
//  значить, чтобы «третий» было наблюдаемо) и ни для чего больше — §2.1 не требует
//  какого-то определённого порядка записи ключей в хранилище, только что после отказа ни
//  один не применён.

import Foundation

extension AppFacadeImpl {

    /// К21 (§2.1, «строки нет — берётся значение из `slice1Defaults`»): каждое поле читается
    /// НЕЗАВИСИМО от остальных одиннадцати — так «поле, заведённое новым изданием контракта»
    /// (§2.1) получает своё умолчание, даже когда остальные одиннадцать уже лежат в хранилище
    /// от предыдущего издания. Пустое хранилище — частный случай: все двенадцать полей падают
    /// в `slice1Defaults`, и результат равен ему целиком (наблюдение К21).
    ///
    /// К22 (инв. 28, «строка есть, а байты не читаются — отказ, а не умолчание»): первое же
    /// нечитаемое поле останавливает сборку — `settingsField` бросает `settingsUnreadable`
    /// немедленно, не собрав остальные одиннадцать. Молчаливый откат к умолчанию здесь
    /// запрещён контрактом дословно — не подставляется НИ ОДНОМУ полю, даже читаемым.
    public func settings() async throws -> AppSettings {
        let defaults = AppSettings.slice1Defaults
        let recordingPolicy = try await settingsField(
            AppSettings.RecordingPolicy.self, key: "recordingPolicy", default: defaults.recordingPolicy
        )
        let armLeadSeconds = try await settingsField(
            Int.self, key: "armLeadSeconds", default: defaults.armLeadSeconds
        )
        let askLeadSeconds = try await settingsField(
            Int.self, key: "askLeadSeconds", default: defaults.askLeadSeconds
        )
        let missingSignalGraceSeconds = try await settingsField(
            Int.self, key: "missingSignalGraceSeconds", default: defaults.missingSignalGraceSeconds
        )
        let silenceStopSeconds = try await settingsField(
            Int.self, key: "silenceStopSeconds", default: defaults.silenceStopSeconds
        )
        let defaultProfileId = try await settingsField(
            String.self, key: "defaultProfileId", default: defaults.defaultProfileId
        )
        let processOnACPowerOnly = try await settingsField(
            Bool.self, key: "processOnACPowerOnly", default: defaults.processOnACPowerOnly
        )
        let processWhileRecording = try await settingsField(
            Bool.self, key: "processWhileRecording", default: defaults.processWhileRecording
        )
        let audioRetentionDays = try await settingsField(
            Int?.self, key: "audioRetentionDays", default: defaults.audioRetentionDays
        )
        let voiceProfilesEnabled = try await settingsField(
            Bool.self, key: "voiceProfilesEnabled", default: defaults.voiceProfilesEnabled
        )
        let notifyParticipants = try await settingsField(
            Bool.self, key: "notifyParticipants", default: defaults.notifyParticipants
        )
        let launchAtLogin = try await settingsField(
            Bool.self, key: "launchAtLogin", default: defaults.launchAtLogin
        )
        return AppSettings(
            recordingPolicy: recordingPolicy, armLeadSeconds: armLeadSeconds, askLeadSeconds: askLeadSeconds,
            missingSignalGraceSeconds: missingSignalGraceSeconds, silenceStopSeconds: silenceStopSeconds,
            defaultProfileId: defaultProfileId, processOnACPowerOnly: processOnACPowerOnly,
            processWhileRecording: processWhileRecording, audioRetentionDays: audioRetentionDays,
            voiceProfilesEnabled: voiceProfilesEnabled, notifyParticipants: notifyParticipants,
            launchAtLogin: launchAtLogin
        )
    }

    /// Инв. 18 («применяет настройки целиком и атомарно: частично применённых не бывает»),
    /// К24: если запись любого ключа отказывает, все уже записанные в ЭТОМ вызове ключи
    /// откатываются к своим значениям ДО вызова (`written`, в обратном порядке) — снаружи
    /// наблюдается так, будто вызова не было вовсе. Читает старое значение каждого ключа
    /// ПЕРЕД тем, как его перезаписать (не одним пакетом заранее): `SettingsRepository` не
    /// даёт транзакции, только `value(forKey:)`/`setValue(_:forKey:)` по одному — это лучшее
    /// приближение атомарности, которое из них строится.
    ///
    /// К23 (§2.1, отображение ключ↔поле, round-trip `DomainJSON`): каждый ключ — дословное
    /// имя поля `AppSettings` (`settingsEntries(for:)`, аргументы `AppSettings.init`), значение
    /// — `DomainJSON.encode` этого поля; `settings()` читает его обратно тем же `DomainJSON.
    /// decode` и, на не тронутом отказом ключе, даёт равное значение — тот же путь кодирования
    /// с обеих сторон.
    public func updateSettings(_ settings: AppSettings) async throws {
        var written: [(key: String, previous: Data?)] = []
        do {
            for (key, data) in try Self.settingsEntries(for: settings) {
                let previous: Data?
                do {
                    previous = try await settingsRepository.value(forKey: key)
                } catch let error as StorageError {
                    throw wrap(error)
                }
                do {
                    try await settingsRepository.setValue(data, forKey: key)
                } catch let error as StorageError {
                    throw wrap(error)
                }
                written.append((key, previous))
            }
        } catch {
            // Восстановление — лучшее усилие (`try?`): если сам откат откажет, наружу всё
            // равно уходит ПЕРВАЯ, настоящая причина отказа, а не вторичная ошибка отката.
            for (key, previous) in written.reversed() {
                try? await settingsRepository.setValue(previous, forKey: key)
            }
            if let facadeError = error as? AppFacadeError {
                throw facadeError
            }
            throw wrapUnexpected(error)
        }
        publish(.settingsChanged(settings))
    }

    /// Двенадцать пар ключ/байты, порядком `AppSettings.init` (см. докстринг файла). Кодирует
    /// значение поля целиком отдельно от остальных одиннадцати — `DomainJSON.encode` работает
    /// на любом `Encodable`, включая примитивы (`Int`, `Bool`, `String`, `Int?`) и замкнутые
    /// перечисления (`RecordingPolicy`), не только на составных типах.
    private static func settingsEntries(for settings: AppSettings) throws -> [(key: String, data: Data)] {
        [
            ("recordingPolicy", try DomainJSON.encode(settings.recordingPolicy)),
            ("armLeadSeconds", try DomainJSON.encode(settings.armLeadSeconds)),
            ("askLeadSeconds", try DomainJSON.encode(settings.askLeadSeconds)),
            ("missingSignalGraceSeconds", try DomainJSON.encode(settings.missingSignalGraceSeconds)),
            ("silenceStopSeconds", try DomainJSON.encode(settings.silenceStopSeconds)),
            ("defaultProfileId", try DomainJSON.encode(settings.defaultProfileId)),
            ("processOnACPowerOnly", try DomainJSON.encode(settings.processOnACPowerOnly)),
            ("processWhileRecording", try DomainJSON.encode(settings.processWhileRecording)),
            ("audioRetentionDays", try DomainJSON.encode(settings.audioRetentionDays)),
            ("voiceProfilesEnabled", try DomainJSON.encode(settings.voiceProfilesEnabled)),
            ("notifyParticipants", try DomainJSON.encode(settings.notifyParticipants)),
            ("launchAtLogin", try DomainJSON.encode(settings.launchAtLogin))
        ]
    }

    /// Читает один ключ, декодирует в объявленный тип поля — `nil` (строки нет) даёт
    /// `defaultValue` (§2.1); байты есть, но не разбираются `DomainJSON` в этот тип — бросает
    /// `settingsUnreadable(key:)` (инв. 28), не подставляя `defaultValue`.
    ///
    /// Возврат РП (MEE-425, комментарий `4d1d45a5`): раньше здесь ловился только `StorageError`
    /// — прочая ошибка хранилища уходила наружу как есть, нарушая инв. 19 («ошибка нижнего
    /// слоя не пропускает наружу свой тип, признак — не перечень имён»). Общий `catch` ниже
    /// закрывает это тем же путём, что уже делает `updateSettings(_:)` своим внешним `catch`.
    private func settingsField<Value: Codable>(
        _ type: Value.Type, key: String, default defaultValue: Value
    ) async throws -> Value {
        let data: Data?
        do {
            data = try await settingsRepository.value(forKey: key)
        } catch let error as StorageError {
            throw wrap(error)
        } catch {
            throw wrapUnexpected(error)
        }
        guard let data else { return defaultValue }
        guard let decoded = try? DomainJSON.decode(Value.self, from: data) else {
            throw AppFacadeError.settingsUnreadable(key: key)
        }
        return decoded
    }
}
