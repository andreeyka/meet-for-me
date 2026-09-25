//  EngineXPCServiceEndToEndTests — MEE-438: настоящий `EngineXPCClient` (публичный API,
//  `TranscriptionServicePort`) против настоящей стороны сервиса. Перечень MEE-370 не называет
//  ни одного критерия, целящего `Services/TranscriptionEngineXPC` напрямую (группа Р и все
//  macOS-критерии проверяют `EngineXPCClient` + тестовый двойник сервиса) — эти тесты
//  подтверждают, что реальный продакшн-диспетчер воспроизводит те же исходы, что уже доказаны
//  в MEE-431 на двойнике, ПЛЮС собственно сервисные обязанности (§2.1 нормализация дат перед
//  encode, ping версии сервиса), которых до появления настоящего кода сервиса проверить
//  было нечем.

import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCServiceEndToEndTests: XCTestCase {

    private func makeSpec(profileId: String = "p1") -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: profileId, language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: false
        )
    }

    func test_pingReturnsRealServiceVersionAndMatchingProtocolVersion() async throws {
        let fixture = RealServiceFixture(serviceVersion: "meet-for-me-engine-xpc-test")

        let version = try await fixture.client.ping()

        XCTAssertEqual(version, "meet-for-me-engine-xpc-test")
    }

    func test_transcribeSucceedsThroughRealProductionServiceDispatch() async throws {
        let fixture = RealServiceFixture()
        configureReadyServiceProfile(fixture.modelCatalog)

        let transcript = try await fixture.client.transcribe(makeSpec()) { _ in }

        XCTAssertEqual(transcript.engine, fixture.transcription.engineId)
        XCTAssertFalse(transcript.segments.isEmpty)
    }

    func test_embedSucceedsThroughRealProductionServiceDispatch() async throws {
        let fixture = RealServiceFixture()
        configureReadyServiceProfile(fixture.modelCatalog, embeddingModelId: "emb-1")

        let vector = try await fixture.client.embed(
            recordingId: UUID(), startMs: 0, endMs: 1_000, profileId: "p1"
        )

        XCTAssertEqual(vector.count, fixture.embedding.dimension)
    }

    /// §2.1: `EngineWire.normalizingDates(_:)` — последний шаг СЕРВИСА перед `encode`, для
    /// исходящего `EngineReply.transcript`. Движок отдаёт `createdAt` с долей секунды МЕЛЬЧЕ
    /// миллисекунды — если бы сервис не нормализовал его сам (полагаясь на то, что вход уже
    /// выровнен), это значение прошло бы насквозь как есть.
    func test_transcriptCreatedAtIsRoundedToMillisecondByRealService() async throws {
        let fixture = RealServiceFixture()
        configureReadyServiceProfile(fixture.modelCatalog)
        let unrounded = Date(timeIntervalSince1970: 1_700_000_000.123_449)
        fixture.transcription.forcedResult = {
            try Transcript(
                recordingId: UUID(), language: "ru", engine: fixture.transcription.engineId,
                modelVersion: "v1", createdAt: unrounded,
                segments: [try Transcript.Segment(
                    startMs: 0, endMs: 100, channel: .mic, speakerCluster: nil,
                    text: "x", textOriginal: nil, textConfidence: 0.5, words: []
                )],
                speakers: []
            )
        }

        let transcript = try await fixture.client.transcribe(makeSpec()) { _ in }

        let expectedMs = (unrounded.timeIntervalSince1970 * 1_000).rounded()
        let actualMs = (transcript.createdAt.timeIntervalSince1970 * 1_000).rounded()
        XCTAssertEqual(actualMs, expectedMs)
        XCTAssertNotEqual(transcript.createdAt, unrounded, "сырое значение не должно было дойти как есть")
    }
}
