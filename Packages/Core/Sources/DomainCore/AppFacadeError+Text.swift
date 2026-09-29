//  AppFacadeError — тексты для человека в `AppErrorView` (C-016 v13, §3.1 и инв. 37; MEE-492).
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен
//
//  ЧТО ЗДЕСЬ И ПОЧЕМУ. §3.1: стабилен только `code`; `message` и `recoverySuggestion` — тексты
//  для человека, они меняются без версии контракта, и критериев на них нет. Инв. 37: UI берёт
//  `AppErrorView` у фасада (`AppFacadeError.view`) и своих текстов поверх не пишет. Значит,
//  человеческий текст обязан собрать фасад: до MEE-492 `message` был `String(describing: self)`,
//  и пользователь читал `notAllowed(reason: "…")`.
//
//  Правило текста: ни имени случая, ни скобок Swift, ни идентификаторов, которые пользователю
//  ничего не говорят. `code` здесь не строится — он в `AppFacadeError.view`.

import Foundation

extension AppFacadeError {

    /// `AppErrorView.message`. У `underlying` — текст вложенного значения как есть (его строят
    /// `wrap` фасада по `UnderlyingErrorText`, MEE-494).
    var humanMessage: String {
        switch self {
        case .underlying(let view):
            return view.message
        case .notFound(let entity, _):
            return Self.notFoundText(entity: entity)
        case .notAllowed(let reason):
            return reason
        case .permissionRequired(let kind):
            return Self.permissionMissingText(kind)
        case .profileNotReady(let profileId, let missingModelIds):
            let head = "Профиль распознавания «\(profileId)» не готов"
            guard !missingModelIds.isEmpty else { return head }
            return head + ": не загружены модели " + missingModelIds.map { "«\($0)»" }.joined(separator: ", ")
        case .settingsUnreadable(let key):
            return "Не удалось прочитать настройку «\(key)»"
        case .jobFailed(_, let type, let message):
            // MEE-494: `message` случая — строка очереди дословно (инв. 31), часто описание значения
            // Swift; показывается её человеческий пересказ (`UnderlyingErrorText.jobFailureDetail`).
            let head = "\(Self.jobTitle(type)) не выполнена"
            guard let detail = UnderlyingErrorText.jobFailureDetail(message) else { return head }
            return "\(head): \(detail)"
        }
    }

    /// `AppErrorView.recoverySuggestion`: что может сделать пользователь; `nil` — сказать нечего.
    var humanRecoverySuggestion: String? {
        switch self {
        case .underlying(let view):
            return view.recoverySuggestion
        case .notFound:
            return "Возможно, это уже удалено — обновите список."
        case .notAllowed:
            return nil
        case .permissionRequired(let kind):
            return Self.permissionSuggestion(kind)
        case .profileNotReady:
            return "Загрузите недостающие модели или выберите другой профиль."
        case .settingsUnreadable:
            return "Откройте настройки и сохраните это значение заново."
        case .jobFailed:
            return "Задачу можно повторить в окне «Встречи»."
        }
    }

    // MARK: - Словари

    /// Имя сущности приходит из фасада и хранилища по-английски (`"Meeting"`, `"Recording"`, …),
    /// регистр не важен. Незнакомое имя — общий текст: английское имя типа пользователю ни к чему.
    static func notFoundText(entity: String) -> String {
        notFoundTexts[entity.lowercased()] ?? "Объект не найден"
    }

    /// Словарь, а не `switch`: сущностей больше, чем допускает `cyclomatic_complexity`.
    private static let notFoundTexts: [String: String] = [
        "meeting": "Встреча не найдена", "meetings": "Встреча не найдена",
        "recording": "Запись не найдена", "recordings": "Запись не найдена",
        "transcript": "Транскрипт не найден", "transcripts": "Транскрипт не найден",
        "segment": "Фрагмент транскрипта не найден", "segments": "Фрагмент транскрипта не найден",
        "session": "Сессия записи не найдена",
        "prompt": "Вопрос о записи уже неактуален",
        "person": "Человек не найден", "persons": "Человек не найден", "people": "Человек не найден",
        "connector": "Подключение календаря не найдено", "connectors": "Подключение календаря не найдено",
        "meetingoutput": "Итоги встречи не найдены",
        "job": "Задача не найдена", "jobs": "Задача не найдена",
        "profile": "Профиль распознавания не найден",
        "model": "Модель не найдена"
    ]

    static func permissionMissingText(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: return "Нет доступа к микрофону"
        case .systemAudioRecording: return "Нет доступа к записи системного звука"
        case .screenRecording: return "Нет доступа к записи экрана и системного звука"
        case .calendars: return "Нет доступа к календарям"
        case .notifications: return "Уведомления не разрешены"
        case .accessibility: return "Нет разрешения на универсальный доступ"
        }
    }

    /// Раздел Системных настроек macOS: права — в «Конфиденциальность и безопасность»,
    /// уведомления — свой раздел верхнего уровня.
    static func permissionSuggestion(_ kind: PermissionKind) -> String {
        let privacy = "Разрешите доступ в Системных настройках → Конфиденциальность и безопасность → "
        switch kind {
        case .microphone: return privacy + "Микрофон."
        case .systemAudioRecording, .screenRecording: return privacy + "Запись экрана и системного звука."
        case .calendars: return privacy + "Календари."
        case .notifications: return "Разрешите уведомления в Системных настройках → Уведомления."
        case .accessibility: return privacy + "Универсальный доступ."
        }
    }

    static func jobTitle(_ type: JobType) -> String {
        switch type {
        case .transcode: return "Подготовка звука"
        case .transcribe: return "Транскрибация"
        case .diarize: return "Разметка говорящих"
        case .attribute: return "Опознание говорящих"
        case .summarize: return "Резюме"
        }
    }
}
