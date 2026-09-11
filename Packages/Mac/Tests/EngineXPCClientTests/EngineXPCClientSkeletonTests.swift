//  EngineXPCClientTests — тесты модуля, владелец: DEV-2
//
//  Тесты пишутся против контракта своего модуля, чужие интерфейсы — через фейки
//  из DomainTestKit (П8). Этот файл — каркас; его можно заменить своими тестами.

import XCTest
import EngineXPCClient

final class EngineXPCClientSkeletonTests: XCTestCase {
    func testTargetBuilds() {
        XCTAssertTrue(true, "Каркас таргета собирается и тесты запускаются")
    }
}
