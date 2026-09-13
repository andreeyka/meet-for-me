//  RightsSystem — швы 1.а и 1.б перечня MEE-74: откуда порт берёт статус права и промпт.
//
//  * `StatusSource` (1.а) отдаёт уже переведённый `PermissionStatus` — вход `request(_:)`;
//  * `SystemReader` (1.б) отдаёт исход системного чтения — то, что вернул системный вызов
//    права, плюс исход «чтение не удалось»; перевод в `PermissionStatus` делает
//    `StatusTranslation`, и он — предмет проверки, а не часть входа.
//
//  Право `.systemAudioRecording` ни к одному из швов не обращается: его статус система не
//  отдаёт (C-007 §«Права, статус которых система не отдаёт»), значение приходит только через
//  `note(observed:for:)`.

import AVFoundation
import DomainCore
import EventKit
import Foundation
import UserNotifications

/// Что контракт говорит о правах поимённо: множество без публичного статуса и наличие промпта.
enum RightsCatalog {

    /// Права, статус которых система не отдаёт. Признак контракта: нет публичного системного
    /// вызова, отдающего статус. Пополнение — правка C-007, а не решение реализатора.
    static let withoutSystemStatus: Set<PermissionKind> = [.systemAudioRecording]

    /// У права есть системный промпт, приносящий исход (инвариант 6). У «Универсального доступа»
    /// диалог только информирует и исхода не приносит (§«Право «Универсальный доступ»»); у права
    /// на системный звук промпт поднимает операция, а не порт (инвариант 12).
    static func hasSystemPrompt(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .microphone, .screenRecording, .calendars, .notifications:
            return true
        case .accessibility, .systemAudioRecording:
            return false
        }
    }
}

/// Исход системного чтения статуса — ровно то, что отдаёт системный вызов права (шов 1.б).
enum SystemReading: Equatable, Sendable {
    case microphone(AVAuthorizationStatus)
    case screenRecording(granted: Bool)
    case calendars(EKAuthorizationStatus)
    case notifications(UNAuthorizationStatus)
    case accessibility(trusted: Bool)
    /// Чтение не удалось: вызов недоступен процессу либо вернул отказ.
    case unreadable
}

/// Шов 1.б: системное чтение и системный промпт.
protocol SystemReader: Sendable {
    func read(_ kind: PermissionKind) async -> SystemReading
    /// Показать системный промпт права и дождаться исхода. Только для прав с промптом.
    func prompt(_ kind: PermissionKind) async -> Bool
}

/// Шов 1.а: текущий статус права и промпт.
protocol StatusSource: Sendable {
    func status(of kind: PermissionKind) async -> PermissionStatus
    func prompt(_ kind: PermissionKind) async -> Bool
}

/// Статус права из системного чтения: перевод `StatusTranslation` поверх `SystemReader`.
final class TranslatingStatusSource: StatusSource, @unchecked Sendable {

    private let reader: SystemReader
    private let lock = NSLock()
    private var promptedThisLaunch: Set<PermissionKind> = []

    init(reader: SystemReader) {
        self.reader = reader
    }

    func status(of kind: PermissionKind) async -> PermissionStatus {
        let reading = await reader.read(kind)
        return StatusTranslation.status(of: kind, reading: reading, promptedThisLaunch: wasPrompted(kind))
    }

    func prompt(_ kind: PermissionKind) async -> Bool {
        let granted = await reader.prompt(kind)
        markPrompted(kind)
        return granted
    }

    private func markPrompted(_ kind: PermissionKind) {
        lock.lock()
        defer { lock.unlock() }
        promptedThisLaunch.insert(kind)
    }

    private func wasPrompted(_ kind: PermissionKind) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return promptedThisLaunch.contains(kind)
    }
}
