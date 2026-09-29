//  EngineXPCClientFailureMessageTests — MEE-454: `engineFailure.message` на ответе
//  `.failed(jobId, EngineError)` — текст самой ошибки, без обёртки имени случая (C-012 §3.2,
//  строка `EngineReply.failed`; §3.3 и C-011 инв. 1 для `invalidResult`). Все девять случаев
//  `EngineError`, настоящий `EngineXPCClient` поверх `NSXPCListener.anonymous()`.

import Foundation
import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientFailureMessageTests: XCTestCase {

    private func engineFailure(for error: EngineError) async throws -> (code: String, message: String) {
        let fixture = XPCFixture()
        configureReadyProfile(fixture.modelCatalog)
        _ = try await fixture.client.ping()
        fixture.service.forcedReplyOverride = { jobId in .failed(jobId, error) }
        let spec = TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
        do {
            _ = try await fixture.client.transcribe(spec) { _ in }
        } catch TranscriptionServiceError.engineFailure(let code, let message) {
            return (code, message)
        }
        XCTFail("ожидался engineFailure для \(error)")
        return ("", "")
    }

    func test_mee454_everyEngineErrorCaseGivesCodeAndUnwrappedMessage() async throws {
        let validationError = DomainValidationError(
            contract: "C-003", type: "Transcript.Word", invariant: 7, path: "confidence", message: "вне 0...1"
        )
        let cases: [FailureCase] = [
            FailureCase(
                .modelMissing(modelId: "asr-1", version: "1.0"), "modelMissing", "modelId: asr-1, version: 1.0"
            ),
            FailureCase(
                .modelIncompatible(modelId: "asr-1", message: "бага"), "modelIncompatible",
                "modelId: asr-1, message: бага"
            ),
            FailureCase(.audioUnreadable(path: "/tmp/a.m4a"), "audioUnreadable", "/tmp/a.m4a"),
            FailureCase(.unsupportedLanguage("xx"), "unsupportedLanguage", "xx"),
            FailureCase(.unsupportedRequest(message: "нет аудио"), "unsupportedRequest", "нет аудио"),
            FailureCase(.outOfMemory, "outOfMemory", "outOfMemory"),
            FailureCase(.cancelled, "cancelled", "cancelled"),
            FailureCase(
                .invalidResult(validationError), "invalidResult", "C-003.Transcript.Word инв. 7, confidence: вне 0...1"
            ),
            FailureCase(.runtimeFailure(message: "сбой"), "runtimeFailure", "сбой")
        ]
        for expectation in cases {
            let outcome = try await engineFailure(for: expectation.error)
            XCTAssertEqual(outcome.code, expectation.code)
            XCTAssertEqual(outcome.message, expectation.message, "случай \(expectation.code)")
        }
    }
}

private struct FailureCase {
    let error: EngineError
    let code: String
    let message: String

    init(_ error: EngineError, _ code: String, _ message: String) {
        self.error = error
        self.code = code
        self.message = message
    }
}
