//  LoginItems — регистрация автозапуска через `SMAppService.mainApp` (шов 2, сторона C-007).
//
//  `register()` на уже зарегистрированном и `unregister()` на незарегистрированном приложении
//  система считает ошибками; порт считает их исполненным желанием и систему не зовёт.
//  Состояние «требует одобрения в системных настройках» — не отказ регистрации: вызов прошёл,
//  но автозапуск включённым не считается, пока пользователь его не одобрил.

import Foundation
import ServiceManagement

/// Шов 2: регистрация автозапуска. Отказ — брошенная ошибка с текстом.
protocol LoginItemRegistry: Sendable {
    func isEnabled() -> Bool
    func setEnabled(_ enabled: Bool) throws
}

final class SystemLoginItems: LoginItemRegistry {

    func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }
}
