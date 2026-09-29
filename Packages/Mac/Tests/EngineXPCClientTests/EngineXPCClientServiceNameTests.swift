//  EngineXPCClientServiceNameTests — MEE-471: публичный вход `init(serviceName:modelCatalog:)`
//  соединяется со встроенным XPC-сервисом приложения (C-012 v10 §3,
//  `Contents/XPCServices/TranscriptionEngine.xpc`) через `NSXPCConnection(serviceName:)`.
//  Проверяется фабрикой `makeConnection` — реальный сервис не нужен: соединение создаётся и не
//  возобновляется (`resume()` не вызывается), так что обращения к системе нет.

import XCTest
import DomainCore
import DomainTestKit
@testable import EngineXPCClient

final class EngineXPCClientServiceNameTests: XCTestCase {

    private let serviceName = "com.example.meetforme.TranscriptionEngine"

    func testServiceNameInitMakesConnectionToThatService() {
        let client = EngineXPCClient(serviceName: serviceName, modelCatalog: FakeModelCatalogPort())

        let connection = client.makeConnection()
        defer { connection.invalidate() }

        XCTAssertEqual(connection.serviceName, serviceName)
    }

    /// К30 без изменений: фабрика — не хранимое значение, каждый вызов даёт НОВОЕ соединение к
    /// тому же имени (пересоздание после обрыва идёт через неё же).
    func testServiceNameFactoryMakesFreshConnectionEachCall() {
        let client = EngineXPCClient(serviceName: serviceName, modelCatalog: FakeModelCatalogPort())

        let first = client.makeConnection()
        let second = client.makeConnection()
        defer {
            first.invalidate()
            second.invalidate()
        }

        XCTAssertFalse(first === second)
        XCTAssertEqual(first.serviceName, serviceName)
        XCTAssertEqual(second.serviceName, serviceName)
    }
}
