//  SettingsOpener — открытие раздела системных настроек (шов 2, сторона C-007).
//
//  Якоря разделов «Конфиденциальность и безопасность» — идентификаторы `Privacy_*` из бинарника
//  `SecurityPrivacyExtension` macOS 26.6; для `.systemAudioRecording` это `Privacy_AudioCapture`
//  («Только запись системного звука»). Уведомления живут отдельным расширением настроек.
//  Гарантируется открытие раздела приватности; точность вкладки контракт не обещает
//  («Что вне контракта»).

import AppKit
import DomainCore
import Foundation

/// Шов 2: открыть раздел настроек для права. Ответ — удалось ли.
protocol SettingsOpener: Sendable {
    func open(_ kind: PermissionKind) async -> Bool
}

enum SettingsPane {

    static func url(for kind: PermissionKind) -> URL? {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .systemAudioRecording: anchor = "Privacy_AudioCapture"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .calendars: anchor = "Privacy_Calendars"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .notifications:
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}

final class SystemSettingsOpener: SettingsOpener {

    func open(_ kind: PermissionKind) async -> Bool {
        guard let url = SettingsPane.url(for: kind) else { return false }
        return await MainActor.run { NSWorkspace.shared.open(url) }
    }
}
