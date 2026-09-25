//  AppSettings — контракт C-016 (MEE-25), «Определение», §2 «Настройки»
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  Только объявления (MEE-289, прецедент формы — MEE-86). Фасад C-016 реализует `app-ui`.
//
//  ОТОБРАЖЕНИЕ НА КЛЮЧИ `app_settings` ЗАДАНО ЭТИМ ОБЪЯВЛЕНИЕМ, А НЕ ТАБЛИЦЕЙ.
//  §2.1 контракта: ключ строки есть имя поля `AppSettings` дословно, в lowerCamelCase,
//  и «одно названное место, где отображение живёт, — объявление `AppSettings` в §2».
//  Поэтому имена и порядок полей здесь дословны по контракту и правятся только вместе с ним.
//
//  `AppSettings.slice1Defaults` НЕ ОБЪЯВЛЕН — но НАХОДКА MEE-289, на которой держалось это
//  отсутствие, устарела. C-016 v10 (основание версии 10, приёмка РП IR-105/MEE-291) сама
//  разводит все двенадцать полей: семь названы контрактом дословно — `armLeadSeconds` 120,
//  `askLeadSeconds` 30, `missingSignalGraceSeconds` 900, `silenceStopSeconds` 300,
//  `audioRetentionDays` nil, `notifyParticipants` false, `voiceProfilesEnabled` false (Q6
//  architecture.md — функция требует явного согласия пользователя). Оставшиеся пять —
//  `recordingPolicy`, `defaultProfileId`, `processOnACPowerOnly`, `processWhileRecording`,
//  `launchAtLogin` — контракт сознательно не называет и явно требует значения от DEV-2 (не
//  ждёт архитектора). Объявление `slice1Defaults` — предмет своей группы плана MEE-410 (Ж),
//  не заведено этим файлом сейчас, чтобы не решать чужую задачу попутно; строка на будущее,
//  не молчаливый долг.
//
//  `ExportFormat` из того же §2 не объявлен: на нём не стоит ни один пункт плана MEE-288,
//  и §6 плана его не называет. Назван в отчёте.

import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    public enum RecordingPolicy: String, Codable, Sendable {
        case auto      // начинать запись самостоятельно
        case ask       // показывать уведомление с кнопкой
        case manual    // только по команде пользователя
    }

    public let recordingPolicy: RecordingPolicy
    public let armLeadSeconds: Int              // за сколько до начала взводить сессию (120)
    public let askLeadSeconds: Int              // за сколько показать уведомление «Записать?» (30)
    public let missingSignalGraceSeconds: Int   // нет сигнала столько после начала → Skipped (900)
    public let silenceStopSeconds: Int          // тишина столько после конца события → стоп (300)
    public let defaultProfileId: String         // C-014
    public let processOnACPowerOnly: Bool
    public let processWhileRecording: Bool
    public let audioRetentionDays: Int?         // nil — хранить бессрочно
    public let voiceProfilesEnabled: Bool
    public let notifyParticipants: Bool         // по умолчанию false (Q5 архитектурного документа)
    public let launchAtLogin: Bool

    public init(
        recordingPolicy: RecordingPolicy,
        armLeadSeconds: Int,
        askLeadSeconds: Int,
        missingSignalGraceSeconds: Int,
        silenceStopSeconds: Int,
        defaultProfileId: String,
        processOnACPowerOnly: Bool,
        processWhileRecording: Bool,
        audioRetentionDays: Int?,
        voiceProfilesEnabled: Bool,
        notifyParticipants: Bool,
        launchAtLogin: Bool
    ) {
        self.recordingPolicy = recordingPolicy
        self.armLeadSeconds = armLeadSeconds
        self.askLeadSeconds = askLeadSeconds
        self.missingSignalGraceSeconds = missingSignalGraceSeconds
        self.silenceStopSeconds = silenceStopSeconds
        self.defaultProfileId = defaultProfileId
        self.processOnACPowerOnly = processOnACPowerOnly
        self.processWhileRecording = processWhileRecording
        self.audioRetentionDays = audioRetentionDays
        self.voiceProfilesEnabled = voiceProfilesEnabled
        self.notifyParticipants = notifyParticipants
        self.launchAtLogin = launchAtLogin
    }
}
