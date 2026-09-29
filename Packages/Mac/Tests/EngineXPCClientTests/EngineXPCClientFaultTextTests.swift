//  EngineXPCClientFaultTextTests — MEE-451, добор по сверке QA (MEE-389, `bfbd0b51`):
//  К25 входы 2 и 3 (код 2 от сервиса — с `messageBytesKey` и без него), К33 и К35 —
//  точные префиксы текста («нераспознанный код транспорта N:», «нарушение протокола
//  ответа:»), которые прежние тесты не закрепляли. Все векторы — настоящий
//  `EngineXPCClient` поверх `NSXPCListener.anonymous()`.

import Foundation
import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientFaultTextTests: XCTestCase {

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    private func readyFixture() async throws -> XPCFixture {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)
        _ = try await fixture.client.ping()
        return fixture
    }

    // MARK: - К25, входы 2 и 3: код 2 от сервиса

    private func messageTooLargeBytes(userInfo: [String: Any]) async throws -> Int? {
        let fixture = try await readyFixture()
        fixture.service.forcedTransportFault = (code: EngineTransportFault.messageTooLarge.rawValue, userInfo: userInfo)
        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался messageTooLarge")
        } catch TranscriptionServiceError.messageTooLarge(let bytes) {
            return bytes
        }
        return nil
    }

    func test_k25_serviceCode2WithMessageBytesKeyMapsToMessageTooLargeWithThatSize() async throws {
        let bytes = try await messageTooLargeBytes(userInfo: [EngineTransportFault.messageBytesKey: 40_000_000])
        XCTAssertEqual(bytes, 40_000_000)
    }

    func test_k25_serviceCode2WithoutMessageBytesKeyMapsToMinusOne() async throws {
        let bytes = try await messageTooLargeBytes(userInfo: [:])
        XCTAssertEqual(bytes, -1)
    }

    func test_k25_serviceCode2WithNonIntMessageBytesKeyMapsToMinusOne() async throws {
        let bytes = try await messageTooLargeBytes(userInfo: [EngineTransportFault.messageBytesKey: "40000000"])
        XCTAssertEqual(bytes, -1)
    }

    // MARK: - К33: точный префикс

    func test_k33_unrecognizedTransportCodeMessageHasExactPrefix() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedTransportFault = (code: 4, userInfo: [:])

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался invalidRequest")
        } catch TranscriptionServiceError.invalidRequest(let message) {
            XCTAssertTrue(message.hasPrefix("нераспознанный код транспорта 4: "), message)
        }
    }

    // MARK: - К35: точный префикс на всех четырёх входах

    private func assertProtocolViolation(
        _ fixture: XPCFixture, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable", file: file, line: line)
        } catch TranscriptionServiceError.serviceUnavailable(let message) {
            XCTAssertTrue(message.hasPrefix("нарушение протокола ответа: "), message, file: file, line: line)
        } catch {
            XCTFail("неверный исход: \(error)", file: file, line: line)
        }
    }

    func test_k35_bothNilMessageHasExactPrefix() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (data: nil, error: nil)
        await assertProtocolViolation(fixture)
    }

    func test_k35_bothSetMessageHasExactPrefix() async throws {
        let fixture = try await readyFixture()
        let data = try EngineWire.encode(EngineReply.pong(serviceVersion: "x", protocolVersion: 1))
        fixture.service.forcedRawResponse = (data: data, error: NSError(domain: "SomeDomain", code: 1))
        await assertProtocolViolation(fixture)
    }

    func test_k35_foreignJobIdMessageHasExactPrefix() async throws {
        let fixture = try await readyFixture()
        let foreignReply = try EngineWire.encode(EngineReply.cancelled(EngineJobId(rawValue: UUID())))
        fixture.service.forcedRawResponse = (data: foreignReply, error: nil)
        await assertProtocolViolation(fixture)
    }

    func test_k35_wrongReplyKindMessageHasExactPrefix() async throws {
        let fixture = try await readyFixture()
        let diarizationResult = try DiarizationResult(turns: [], speakers: [], modelVersion: "v")
        fixture.service.forcedReplyOverride = { jobId in .diarization(jobId, diarizationResult) }
        await assertProtocolViolation(fixture)
    }
}
