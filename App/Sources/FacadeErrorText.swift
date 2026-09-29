//  FacadeErrorText — подписи для строки UI: отказ `AppErrorView` одной строкой, названия прав
//  и задач. Общее для меню-бара (MEE-473) и окна «Встречи» (MEE-474). Чистые функции, без SwiftUI.
//
//  Перевод ошибки в `AppErrorView` здесь не живёт: это `AppFacadeError.view` фасада (C-016 v13
//  инв. 37, MEE-487 п. 1). UI переводит только пойманную `AppFacadeError`; ошибка другого типа
//  (`CancellationError`) не переводится и не показывается — `shownError(_:)` отдаёт `nil`.
//
//  Модуль: app-ui · Владелец: DEV-1 · Слой: UI

import DomainCore
import Foundation

enum FacadeErrorText {

    /// Бросок фасада → что показать. `nil` — не `AppFacadeError` (инв. 37): не показывается.
    static func shownError(_ error: Error) -> AppErrorView? {
        (error as? AppFacadeError)?.view
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

    /// «Ошибка: <текст>. <совет>» — одна строка. Без совета, но с правом (`permissionKind`,
    /// C-016 §3.1: отказ вызван одним системным правом) — называем право.
    static func line(_ view: AppErrorView) -> String {
        let suggestion = view.recoverySuggestion
            ?? view.permissionKind.map { "Нужно право: \(permissionTitle($0)) — Системные настройки" }
        return "Ошибка: \(view.message)\(suggestion.map { ". \($0)" } ?? "")"
    }
}
