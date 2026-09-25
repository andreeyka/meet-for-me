//  ServiceConnectionDelegate, ExportedRequestHandler — вся `NSObject`/`@objc`-обвязка стороны
//  сервиса (MEE-438): `NSXPCListenerDelegate` и экспорт `EngineXPCServiceProtocol`. Ни строки
//  диспетчерской логики — та целиком в `EngineXPCRequestHandler` (`EngineXPCService`,
//  Packages/Mac), которому оба типа здесь только переадресуют вызовы. Почему обвязка заведена
//  именно тут, а не в самом `EngineXPCService`, — заголовок `EngineXPCRequestHandler.swift`
//  (символьный граф CI `Packages/Core`/`Packages/Mac`; этот каталог им не покрыт).
//
//  Модуль: engine-xpc · Владелец: DEV-2 · Слой: движок
//
//  РАСКРЫТИЕ по возврату РП (MEE-438, 12:15 UTC): этот файл не покрыт автоматическим тестом —
//  `swift build`/`swift test` не видят `Services/TranscriptionEngineXPC` вовсе (тот же довод,
//  что и в заголовке `EngineXPCRequestHandler.swift`, только с обратным знаком: то, что спасает
//  от символьного графа, здесь же закрывает путь к SwiftPM-тестам). Его почти буквальная копия
//  (`TestServiceConnectionDelegate`/`TestExportedRequestHandler`,
//  `Packages/Mac/Tests/EngineXPCServiceTests/TestSupport.swift`) тестируется целиком —
//  но проверяет СЕБЯ, не этот файл. Вынести общий код в `EngineXPCService` нельзя тем же
//  доводом, каким он оттуда изгнан (`NSObject`/`@objc` там неразрешённо публичны). Правильность
//  этого файла опирается на его буквальное совпадение с тестовой копией — при правке одного
//  обязательна такая же правка другого, вручную; альтернатива (файл `allowed-types/
//  EngineXPCService.json`, тестируемый общий тип внутри пакета) не разрешена этой задачей.
//  «Каркас app-ui» (XcodeGen + xcodebuild) в CI компилирует этот файл и доказывает, что он хотя
//  бы СОБИРАЕТСЯ вместе с настоящим `TranscriptionEngine.xpc` — не то же самое, что тест
//  поведения.

import EngineXPCClient
import EngineXPCService
import Foundation

final class ServiceConnectionDelegate: NSObject, NSXPCListenerDelegate {
    private let engines: EngineBundle
    private let serviceVersion: String

    init(engines: EngineBundle, serviceVersion: String) {
        self.engines = engines
        self.serviceVersion = serviceVersion
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: EngineXPCServiceProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: EngineXPCClientProtocol.self)
        let handler = EngineXPCRequestHandler(
            engines: engines, serviceVersion: serviceVersion,
            pushProgress: { [weak newConnection] data in
                guard let proxy = newConnection?.remoteObjectProxyWithErrorHandler({ _ in }) as? EngineXPCClientProtocol
                else { return }
                proxy.didReceiveProgress(data)
            }
        )
        let exportedObject = ExportedRequestHandler(handler: handler)
        newConnection.exportedObject = exportedObject
        // Гигиена сверх контракта (см. `EngineXPCRequestHandler.invalidate()`) — обрыв
        // соединения обрывает и незавершённую работу, затеянную ради него.
        newConnection.interruptionHandler = { [weak exportedObject] in exportedObject?.handler.invalidate() }
        newConnection.invalidationHandler = { [weak exportedObject] in exportedObject?.handler.invalidate() }
        newConnection.resume()
        return true
    }
}

/// Единственная обязанность — переадресовать `send(_:reply:)` протокола настоящему
/// `EngineXPCRequestHandler`; сам класс существует только потому, что `NSXPCConnection`
/// требует у `exportedObject` быть настоящим `NSObject`, совместимым с Objective-C рантаймом.
final class ExportedRequestHandler: NSObject, EngineXPCServiceProtocol {
    let handler: EngineXPCRequestHandler

    init(handler: EngineXPCRequestHandler) {
        self.handler = handler
    }

    func send(_ requestData: Data, reply: @escaping (Data?, Error?) -> Void) {
        handler.handle(requestData, reply: reply)
    }
}
