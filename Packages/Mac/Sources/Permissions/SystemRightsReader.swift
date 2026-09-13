//  SystemRightsReader — системное чтение статуса и системный промпт каждого права. Единственное
//  место модуля, которое говорит с TCC.
//
//  Ни одного приватного вызова (C-007 §«Приватный API»), ни одного process tap («Поведение»:
//  создание tap — работа `capture`). Доверие «Универсального доступа» читается
//  `AXIsProcessTrusted()` — у него нет параметра опций, и поднять диалог ему нечем.
//
//  Центр уведомлений вне бандла приложения: `UNUserNotificationCenter.current()` в процессе без
//  собственного `.app` (например, `xctest`) роняет процесс, а не возвращает ошибку. Поэтому
//  чтение и промпт этого права идут только при наличии бандла приложения; иначе чтение
//  «не удалось».

import ApplicationServices
import AVFoundation
import CoreGraphics
import DomainCore
import EventKit
import Foundation
import UserNotifications

final class SystemRightsReader: SystemReader {

    /// Процесс запущен из бандла приложения — условие, при котором центр уведомлений доступен.
    static var hasApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    func read(_ kind: PermissionKind) async -> SystemReading {
        switch kind {
        case .microphone:
            return .microphone(AVCaptureDevice.authorizationStatus(for: .audio))
        case .screenRecording:
            return .screenRecording(granted: CGPreflightScreenCaptureAccess())
        case .calendars:
            return .calendars(EKEventStore.authorizationStatus(for: .event))
        case .notifications:
            return await notifications()
        case .accessibility:
            return .accessibility(trusted: AXIsProcessTrusted())
        case .systemAudioRecording:
            return .unreadable
        }
    }

    func prompt(_ kind: PermissionKind) async -> Bool {
        switch kind {
        case .microphone:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        case .calendars:
            return (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        case .notifications:
            return await requestNotifications()
        case .accessibility, .systemAudioRecording:
            return false
        }
    }

    private func notifications() async -> SystemReading {
        guard Self.hasApplicationBundle else { return .unreadable }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return .notifications(settings.authorizationStatus)
    }

    private func requestNotifications() async -> Bool {
        guard Self.hasApplicationBundle else { return false }
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}
