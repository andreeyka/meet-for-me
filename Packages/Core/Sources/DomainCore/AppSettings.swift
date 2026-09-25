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
//  `AppSettings.slice1Defaults` (MEE-425, IR-105 закрыт C-016 v10) — семь значений, которые
//  контракт называет сам (К53 перечня MEE-401), и пять — требование к DEV-2 с доковым
//  комментарием на месте присвоения (К54/К55), см. определение константы ниже.
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

    /// К53 перечня MEE-401 (дельта АА): семь значений, которые контракт называет сам —
    /// `armLeadSeconds`/`askLeadSeconds`/`missingSignalGraceSeconds`/`silenceStopSeconds`
    /// (§2, дословные числа), `audioRetentionDays`/`voiceProfilesEnabled`/`notifyParticipants`
    /// (architecture.md Q5/Q6 — согласие пользователя требуется явно). Пять оставшихся —
    /// требование к DEV-2 (IR-105): architecture.md решения по ним не содержит вовсе, а
    /// `defaultProfileId` не может быть архитектурным решением в принципе — зависит от
    /// каталога моделей C-014 на конкретной машине. К54/К55 проверяют факт присвоения и
    /// факт докового комментария на месте, не сами значения (контракт их не даёт).
    public static let slice1Defaults = AppSettings(
        // К55, выбор DEV-1: .ask — при первом запуске приложение спрашивает пользователя
        // перед началом записи, вместо того чтобы начинать её самостоятельно (.auto) или
        // требовать ручной команды (.manual) — наименее внезапное поведение до того, как
        // пользователь сам настроил политику.
        recordingPolicy: .ask,
        armLeadSeconds: 120,
        askLeadSeconds: 30,
        missingSignalGraceSeconds: 900,
        silenceStopSeconds: 300,
        // К54, выбор DEV-1: пустая строка — значение зависит от каталога моделей C-014 на
        // конкретной машине, не от архитектуры (IR-105), и не может быть названо здесь ни
        // одним конкретным идентификатором профиля; пустая строка — наблюдаемый факт «профиль
        // ещё не выбран», а не имя настоящего профиля. Подстановка реального значения после
        // первого чтения каталога C-014 — обязанность вызывающей стороны, вне этого файла.
        defaultProfileId: "",
        // К55, выбор DEV-1: false — фоновая обработка идёт независимо от питания, пока
        // пользователь явно не включит экономию энергии в настройках.
        processOnACPowerOnly: false,
        // К55, выбор DEV-1: false — обработка не запускается параллельно с самой записью по
        // умолчанию, чтобы не конкурировать с ней за ресурсы на слабой машине.
        processWhileRecording: false,
        audioRetentionDays: nil,
        voiceProfilesEnabled: false,
        notifyParticipants: false,
        // К55, выбор DEV-1: false — приложение не запускается при входе в систему само, пока
        // пользователь не включит это явно в настройках.
        launchAtLogin: false
    )
}
