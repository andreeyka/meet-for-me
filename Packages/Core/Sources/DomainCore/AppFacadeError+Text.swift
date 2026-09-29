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

    /// `AppErrorView.message`. У `underlying` — текст вложенного значения как есть.
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
            let head = "\(Self.jobTitle(type)) не выполнена"
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? head : "\(head): \(detail)"
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
        switch entity.lowercased() {
        case "meeting", "meetings": return "Встреча не найдена"
        case "recording", "recordings": return "Запись не найдена"
        case "transcript", "transcripts": return "Транскрипт не найден"
        case "segment", "segments": return "Фрагмент транскрипта не найден"
        case "session": return "Сессия записи не найдена"
        case "prompt": return "Вопрос о записи уже неактуален"
        case "person", "persons", "people": return "Человек не найден"
        case "connector", "connectors": return "Подключение календаря не найдено"
        case "meetingoutput": return "Итоги встречи не найдены"
        case "job", "jobs": return "Задача не найдена"
        case "profile": return "Профиль распознавания не найден"
        case "model": return "Модель не найдена"
        default: return "Объект не найден"
        }
    }

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
