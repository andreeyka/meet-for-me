//  Возврат РП по MEE-390 (24.09, 20:30 UTC): C-011 §0 дословно — все ошибки `EngineOwner`
//  представимости (ступень (в), C-001 §0.2 п. 9) обязаны нести `contract == "C-001"`, а не
//  контракт типа-владельца поля (то был мой перенос соглашения `DomainOwner`, которому
//  C-011 §0 не следует). Тест ловит регресс на границе, не только на пяти вызовах напрямую.

import XCTest
import DomainCore
import EngineKit

final class EngineOwnerContractTests: XCTestCase {

    func test_engineOwnerRepresentabilityErrorCarriesContractC001() throws {
        do {
            _ = try AudioRef(
                recordingId: EngineFixtures.recordingId, channel: .mic, fileURL: EngineFixtures.fileURL,
                sampleRate: 1 << 60, channelCount: 1, offsetMs: 0
            )
            XCTFail("ожидался DomainValidationError: 2^60 вне диапазона представимости Double (§0.2 п. 9)")
        } catch let error as DomainValidationError {
            XCTAssertEqual(error.contract, "C-001")
            XCTAssertEqual(error.invariant, 0)
            XCTAssertEqual(error.type, "AudioRef")
            XCTAssertEqual(error.path, "sampleRate")
        }
    }
}
