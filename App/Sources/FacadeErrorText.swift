//  FacadeErrorText — бросок `AppFacade` → `AppErrorView` для строки UI и подписи прав. Общее
//  для меню-бара (MEE-473) и окна «Встречи» (MEE-474). Чистые функции, без SwiftUI.
//
//  Почему копия правила фасада: `AppFacadeImpl.errorView(for:)` — internal, публичного
//  перевода C-016 не даёт (IR-147 п. 2, MEE-476). Код строится по C-016 §3.1
//  (`facade.<имя случая>`) явным `switch` без `default:` (MEE-478 п. 2): новый случай
//  `AppFacadeError` станет ошибкой компиляции здесь, а не молча уедет в чужой код. Если IR-147
//  сделает перевод публичным — эта копия удаляется, UI зовёт фасад.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

enum FacadeErrorText {

    static func view(for error: Error) -> AppErrorView {
        guard let facadeError = error as? AppFacadeError else {
            return AppErrorView(
                code: "app.internalError", message: String(describing: error),
                recoverySuggestion: nil, permissionKind: nil
            )
        }
        switch facadeError {
        case .underlying(let view):
            return view
        case .permissionRequired(let kind):
            return AppErrorView(
                code: "facade.permissionRequired",
                message: "Нет права: \(permissionTitle(kind))",
                recoverySuggestion: "Разрешите доступ в Системных настройках",
                permissionKind: kind
            )
        case .notAllowed(let reason):
            return plain("notAllowed", message: reason)
        case .notFound(let entity, let id):
            return plain("notFound", message: "\(entity) \(id) не найден")
        case .profileNotReady(let profileId, let missing):
            return plain(
                "profileNotReady",
                message: "Профиль \(profileId) не готов: нет моделей \(missing.joined(separator: ", "))"
            )
        case .settingsUnreadable(let key):
            return plain("settingsUnreadable", message: "Не удалось прочитать настройку \(key)")
        case .jobFailed(_, let type, let message):
            return plain("jobFailed", message: "\(jobTitle(type)): \(message)")
        }
    }

    private static func plain(_ caseName: String, message: String) -> AppErrorView {
        AppErrorView(code: "facade.\(caseName)", message: message, recoverySuggestion: nil, permissionKind: nil)
    }

    static func permissionTitle(_ kind: PermissionKind) -> String {
        switch kind {
        case .microphone: return "микрофон"
        case .systemAudioRecording: return "запись системного звука"
        case .screenRecording: return "запись экрана и звука"
        case .calendars: return "календари"
        case .notifications: return "уведомления"
        case .accessibility: return "универсальный доступ"
        }
    }

    static func jobTitle(_ type: JobType) -> String {
        switch type {
        case .transcode: return "Перекодирование"
        case .transcribe: return "Транскрибация"
        case .diarize: return "Разметка говорящих"
        case .attribute: return "Опознание говорящих"
        case .summarize: return "Резюме"
        }
    }

    /// «Ошибка: <текст>. <совет>» — одна строка.
    static func line(_ view: AppErrorView) -> String {
        let suggestion = view.recoverySuggestion.map { ". \($0)" } ?? ""
        return "Ошибка: \(view.message)\(suggestion)"
    }
}
