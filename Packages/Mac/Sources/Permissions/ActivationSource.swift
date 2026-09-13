//  ActivationSource — сигнал «приложение вернулось в активное состояние» (шов 2, сторона C-007).
//
//  По нему порт перечитывает снимок: TCC-статус мог измениться, пока пользователь был
//  в системных настройках, и система об этом не уведомляет (C-007 «Поведение», `changes()`).

import AppKit
import Foundation

protocol ActivationSource: Sendable {
    func start(_ handler: @escaping @Sendable () -> Void)
    func stop()
}

final class AppActivationSource: ActivationSource, @unchecked Sendable {

    private let lock = NSLock()
    private var token: NSObjectProtocol?

    func start(_ handler: @escaping @Sendable () -> Void) {
        let token = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                           object: nil, queue: nil) { _ in handler() }
        lock.lock()
        self.token = token
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let current = token
        token = nil
        lock.unlock()
        if let current {
            NotificationCenter.default.removeObserver(current)
        }
    }
}
