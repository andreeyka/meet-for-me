//  PowerSignals — системные уведомления о сне, дисплее, питании и тепле (шов 2, сторона C-008).
//
//  Уведомление говорит только «что-то изменилось»; значение порт перечитывает у `PowerReader`
//  и публикует событие лишь при фактической смене (инвариант 7). Сон и дисплей идут событиями
//  как есть: `NSWorkspace` шлёт `willSleep` до засыпания, и порт его не задерживает.

import AppKit
import Foundation
import IOKit.ps

enum PowerSignal: Sendable {
    case willSleep, didWake, screensDidSleep, screensDidWake
    case powerSourcesDidChange, thermalStateDidChange, powerStateDidChange
}

protocol PowerSignalSource: Sendable {
    func start(_ handler: @escaping @Sendable (PowerSignal) -> Void)
    func stop()
}

final class SystemPowerSignals: PowerSignalSource, @unchecked Sendable {

    private static let workspaceSignals: [Notification.Name: PowerSignal] = [
        NSWorkspace.willSleepNotification: .willSleep,
        NSWorkspace.didWakeNotification: .didWake,
        NSWorkspace.screensDidSleepNotification: .screensDidSleep,
        NSWorkspace.screensDidWakeNotification: .screensDidWake
    ]

    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    private var runLoopSource: CFRunLoopSource?
    private var handler: (@Sendable (PowerSignal) -> Void)?

    deinit {
        stop()
    }

    func start(_ handler: @escaping @Sendable (PowerSignal) -> Void) {
        stop()
        let workspace = NSWorkspace.shared.notificationCenter
        var tokens = Self.workspaceSignals.map { name, signal in
            workspace.addObserver(forName: name, object: nil, queue: nil) { _ in handler(signal) }
        }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                         object: nil, queue: nil) { _ in handler(.thermalStateDidChange) })
        tokens.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange,
                                         object: nil, queue: nil) { _ in handler(.powerStateDidChange) })
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<SystemPowerSignals>.fromOpaque(context).takeUnretainedValue().deliverPowerSources()
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        lock.lock()
        self.handler = handler
        self.tokens = tokens
        runLoopSource = source
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let tokens = self.tokens
        let source = runLoopSource
        self.tokens = []
        runLoopSource = nil
        handler = nil
        lock.unlock()
        for token in tokens {
            NotificationCenter.default.removeObserver(token)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    private func deliverPowerSources() {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(.powerSourcesDidChange)
    }
}
