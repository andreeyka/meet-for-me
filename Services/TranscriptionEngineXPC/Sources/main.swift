//  TranscriptionEngineXPC — точка входа XPC-сервиса
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок
//
//  Каталог принадлежит владельцу модуля: файлы здесь изменяет только он (П1), кроме
//  `project.yml` в корне репозитория — тот отдельно принадлежит архитектору (module-map.md,
//  §2) и заводит сам таргет (MEE-430). Всё, что пересекает границу модуля, описано
//  контрактом архитектора и меняется только через interface-request (П2, П6).
//
//  Каркас (MEE-430): `NSXPCListener.service()` — стандартная точка входа встроенного
//  XPC-сервиса (`Contents/XPCServices/…` в бандле App, C-012 v10) — принимает соединение и
//  сразу отклоняет его. Экспорт объекта и делегирование в протоколы `EngineKit` —
//  предмет MEE-431 (DEV-2, «сторона сервиса»): `NSXPCListener.anonymous()` для тестов
//  в одном процессе на CI — там же, эта точка входа его не заменяет и не использует.

import Foundation

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Каркас: кода нет намеренно (MEE-431 задаёт exportedInterface/exportedObject).
        false
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
