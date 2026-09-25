//  EngineXPCClientTests — план MEE-389 (engine-xpc, часть 2, MEE-431): рукопожатие версии
//  протокола (К21), преждевременный отказ на размере сообщения (К25), расписка каталога
//  моделей вокруг transcribe/embed (К46, К53).

import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientTests: XCTestCase {

    private func makeSpec(profileId: String = "p1", language: String? = nil) -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: profileId, language: language,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    // MARK: - К21: рукопожатие версии протокола

    func test_k21_pingPongProtocolVersionMatch() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)

        let version = try await fixture.client.ping()

        XCTAssertEqual(version, "test-service")
    }

    func test_k21_protocolVersionMismatchBlocksWorkRequestBeforeSending() async throws {
        let service = TestEngineXPCService()
        service.protocolVersionOverride = EngineWire.protocolVersion + 1
        let fixture = XPCFixture(service: service)
        configureReadyProfile(fixture.modelCatalog)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался protocolVersionMismatch")
        } catch TranscriptionServiceError.protocolVersionMismatch(let client, let serviceVersion) {
            XCTAssertEqual(client, EngineWire.protocolVersion)
            XCTAssertEqual(serviceVersion, EngineWire.protocolVersion + 1)
        }
        // Рукопожатие (ping) — один вызов; сам transcribe до транспорта не дошёл.
        XCTAssertEqual(service.sendCount, 1, "рабочий запрос не должен был уйти вовсе")
    }

    // MARK: - К25: превышение размера сообщения ловится до транспорта

    func test_k25_oversizedRequestThrowsMessageTooLargeBeforeTransport() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)
        // Рукопожатие сперва, чтобы изолировать счётчик отправок от одного лишнего ping.
        _ = try await fixture.client.ping()
        let sendsBeforeAttempt = fixture.service.sendCount

        let hugeLanguage = String(repeating: "a", count: 40_000_000)
        do {
            _ = try await fixture.client.transcribe(makeSpec(language: hugeLanguage)) { _ in }
            XCTFail("ожидался messageTooLarge")
        } catch TranscriptionServiceError.messageTooLarge(let bytes) {
            XCTAssertGreaterThan(bytes, EngineWire.maxMessageBytes)
        }
        XCTAssertEqual(fixture.service.sendCount, sendsBeforeAttempt, "запрос не должен был дойти до транспорта")
        // К53: beginUse уже состоялся (модели резолвятся раньше построения запроса) —
        // endUse обязан погасить его, даже когда отправка так и не случилась.
        XCTAssertEqual(fixture.modelCatalog.endUseCallCount, fixture.modelCatalog.beginUseSuccessCount)
    }

    // MARK: - К46: modelsNotReady до отправки запроса движку

    func test_k46_resolveFailureGivesModelsNotReadyWithoutTransportSend() async throws {
        let fixture = XPCFixture()
        fixture.modelCatalog.failResolve(.unknownProfile(id: "p1"), forProfileId: "p1")
        _ = try await fixture.client.ping()
        let sendsBeforeAttempt = fixture.service.sendCount

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался modelsNotReady")
        } catch TranscriptionServiceError.modelsNotReady(let profileId, _) {
            XCTAssertEqual(profileId, "p1")
        }
        XCTAssertEqual(fixture.service.sendCount, sendsBeforeAttempt)
    }

    func test_k46_beginUseFailureGivesModelsNotReadyWithoutTransportSend() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)
        fixture.modelCatalog.forcedBeginUseError = .insufficientDiskSpace(requiredBytes: 1, availableBytes: 0)
        _ = try await fixture.client.ping()
        let sendsBeforeAttempt = fixture.service.sendCount

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался modelsNotReady")
        } catch TranscriptionServiceError.modelsNotReady(let profileId, _) {
            XCTAssertEqual(profileId, "p1")
        }
        XCTAssertEqual(fixture.service.sendCount, sendsBeforeAttempt)
    }

    /// К46 (второй вход): `embed` — тот же порядок, `beginUse` до отправки.
    func test_k46_embedResolveFailureGivesModelsNotReadyWithoutTransportSend() async throws {
        let fixture = XPCFixture()
        fixture.modelCatalog.failResolve(.unknownProfile(id: "p1"), forProfileId: "p1")
        _ = try await fixture.client.ping()
        let sendsBeforeAttempt = fixture.service.sendCount

        do {
            _ = try await fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")
            XCTFail("ожидался modelsNotReady")
        } catch TranscriptionServiceError.modelsNotReady(let profileId, _) {
            XCTAssertEqual(profileId, "p1")
        }
        XCTAssertEqual(fixture.service.sendCount, sendsBeforeAttempt)
    }

    // MARK: - К53: beginUse/endUse парны на успехе, отказе и обеих команд

    func test_k53_transcribeSuccessPairsBeginUseWithEndUse() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)

        _ = try await fixture.client.transcribe(makeSpec()) { _ in }

        XCTAssertEqual(fixture.modelCatalog.beginUseSuccessCount, 1)
        XCTAssertEqual(fixture.modelCatalog.endUseCallCount, 1)
        XCTAssertEqual(fixture.modelCatalog.endUseEffectiveCount, 1)
    }

    func test_k53_embedSuccessPairsBeginUseWithEndUse() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog, embeddingModelId: "emb-1")

        _ = try await fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")

        XCTAssertEqual(fixture.modelCatalog.beginUseSuccessCount, 1)
        XCTAssertEqual(fixture.modelCatalog.endUseCallCount, 1)
    }

    func test_k53_engineErrorStillReleasesModelUseToken() async throws {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)
        fixture.service.forcedTransportFault = (
            code: EngineTransportFault.invalidRequest.rawValue, userInfo: [NSLocalizedDescriptionKey: "boom"]
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался invalidRequest")
        } catch TranscriptionServiceError.invalidRequest {
            // ожидаемо
        }
        XCTAssertEqual(fixture.modelCatalog.beginUseSuccessCount, 1)
        XCTAssertEqual(fixture.modelCatalog.endUseCallCount, 1, "расписка обязана погаситься даже на отказе движка")
    }
}
