//  EngineXPCClientErrorMappingTests — план MEE-389: К31 (мисматч версии протокола на любом
//  методе), К33 (нераспознанный код транспорта), К35 (malformed reply — оба пусты/оба
//  заданы/чужой jobId/не тот род), К36 (испорченные байты ответа vs. `.failed(invalidResult)`
//  в разобранном ответе), К37 (код `engineFailure` — имя случая дословно; незапрошенная
//  отмена), К39 (разобранный кадр, не подходящий ни одной строке §3.2).

import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientErrorMappingTests: XCTestCase {

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    private func readyFixture(embeddingModelId: String? = nil) async throws -> XPCFixture {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog, embeddingModelId: embeddingModelId)
        _ = try await fixture.client.ping()   // рукопожатие отдельно от проверяемого вызова
        return fixture
    }

    // MARK: - К31: код 1 на любом методе, не только ping

    func test_k31_protocolVersionMismatchOnEmbedBothKeysPresent() async throws {
        let fixture = try await readyFixture(embeddingModelId: "emb-1")
        fixture.service.forcedTransportFault = (
            code: EngineTransportFault.protocolVersionMismatch.rawValue,
            userInfo: [
                EngineTransportFault.clientProtocolVersionKey: 9,
                EngineTransportFault.serviceProtocolVersionKey: 7
            ]
        )

        do {
            _ = try await fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")
            XCTFail("ожидался protocolVersionMismatch")
        } catch TranscriptionServiceError.protocolVersionMismatch(let client, let service) {
            XCTAssertEqual(client, 9)
            XCTAssertEqual(service, 7)
        }
    }

    func test_k31_protocolVersionMismatchMissingKeysGiveMinusOne() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedTransportFault = (
            code: EngineTransportFault.protocolVersionMismatch.rawValue, userInfo: [:]
        )

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался protocolVersionMismatch")
        } catch TranscriptionServiceError.protocolVersionMismatch(let client, let service) {
            XCTAssertEqual(client, -1)
            XCTAssertEqual(service, -1)
        }
    }

    // MARK: - К33: код 4 (сервис новее клиента) — вне диапазона

    func test_k33_unrecognizedTransportCodeMapsToInvalidRequest() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedTransportFault = (code: 4, userInfo: [:])

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался invalidRequest")
        } catch TranscriptionServiceError.invalidRequest(let message) {
            XCTAssertTrue(message.contains("4"), "сообщение обязано называть код: \(message)")
        }
    }

    // MARK: - К35: нарушение протокола ответа

    func test_k35_bothDataAndErrorNilIsMalformed() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (data: nil, error: nil)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    func test_k35_bothDataAndErrorSetIsMalformed() async throws {
        let fixture = try await readyFixture()
        let data = try EngineWire.encode(EngineReply.pong(serviceVersion: "x", protocolVersion: 1))
        let error = NSError(domain: "SomeDomain", code: 1)
        fixture.service.forcedRawResponse = (data: data, error: error)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    func test_k35_foreignJobIdIsMalformed() async throws {
        let fixture = try await readyFixture()
        let foreignReply = try EngineWire.encode(EngineReply.cancelled(EngineJobId(rawValue: UUID())))
        fixture.service.forcedRawResponse = (data: foreignReply, error: nil)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    func test_k35_wrongReplyKindIsMalformed() async throws {
        let fixture = try await readyFixture()
        let diarizationResult = try DiarizationResult(turns: [], speakers: [], modelVersion: "v")
        fixture.service.forcedReplyOverride = { jobId in .diarization(jobId, diarizationResult) }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }

    // MARK: - К36: испорченные байты vs. разобранный `.failed(invalidResult)`

    func test_k36_corruptedReplyBytesGivesServiceUnavailable() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (data: Data([0xFF, 0x00, 0x01, 0x02]), error: nil)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable(let message) {
            XCTAssertTrue(message.contains("не разобран"), message)
        }
    }

    func test_k36_parsedInvalidResultGivesEngineFailureNotServiceUnavailable() async throws {
        let fixture = try await readyFixture()
        let validationError = DomainValidationError(
            contract: "C-003", type: "Transcript", invariant: 1, path: "segments", message: "тест"
        )
        fixture.service.forcedReplyOverride = { jobId in .failed(jobId, .invalidResult(validationError)) }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался engineFailure")
        } catch TranscriptionServiceError.engineFailure(let code, _) {
            XCTAssertEqual(code, "invalidResult")
        }
    }

    // MARK: - К37: код engineFailure — имя случая дословно; незапрошенная отмена

    func test_k37_engineFailureCodeNamedAfterEngineErrorCase() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedReplyOverride = { jobId in
            .failed(jobId, .modelIncompatible(modelId: "m", message: "бага"))
        }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался engineFailure")
        } catch TranscriptionServiceError.engineFailure(let code, _) {
            XCTAssertEqual(code, "modelIncompatible")
        }
    }

    func test_k37_unsolicitedCancelledReplyMapsToCancelled() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedReplyOverride = { jobId in .cancelled(jobId) }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался cancelled")
        } catch TranscriptionServiceError.cancelled {
            // ожидаемо
        }
    }

    // MARK: - К39: разобранный кадр, не подходящий ни одной строке §3.2

    func test_k39_unmappedParsedReplyGivesServiceUnavailable() async throws {
        let fixture = try await readyFixture()
        // `.pong` в ответ на `.transcribe` — разобрано штатно, но не подходит ни одному
        // ожидаемому виду ответа для этого вызова.
        fixture.service.forcedReplyOverride = { _ in
            .pong(serviceVersion: "x", protocolVersion: EngineWire.protocolVersion)
        }

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался serviceUnavailable")
        } catch TranscriptionServiceError.serviceUnavailable {
            // ожидаемо
        }
    }
}
