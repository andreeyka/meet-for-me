//  EngineXPCClientReplyFieldTests — MEE-451, добор macOS-половин по сверке QA (MEE-389,
//  `bfbd0b51`): К2 (векторы `invariant 0`/`7` у `Transcript.Word.confidence` через настоящий
//  `EngineXPCClient`) и К15 направления «сервис → клиент» (пять полей `DiarizationResult.Turn`/
//  `EmbeddingResult`, испорченные байтами ответа). Направление «клиент → сервис» К15 — в
//  `EngineXPCServiceTests/EngineXPCClientRequestFieldTests.swift`: там нужен настоящий
//  диспетчер сервиса, который и пишет префикс «decoding: ».

import Foundation
import XCTest
import DomainCore
import EngineKit
@testable import EngineXPCClient

final class EngineXPCClientReplyFieldTests: XCTestCase {

    private func makeSpec() -> TranscriptionJobSpec {
        TranscriptionJobSpec(
            recordingId: UUID(), profileId: "p1", language: nil,
            wantWordTimestamps: true, diarizeSystemChannel: true
        )
    }

    private func readyFixture(
        service: TestEngineXPCService = TestEngineXPCService(), embeddingModelId: String? = nil
    ) async throws -> XPCFixture {
        let fixture = XPCFixture(service: service)
        configureReadyProfile(fixture.modelCatalog, embeddingModelId: embeddingModelId)
        _ = try await fixture.client.ping()
        return fixture
    }

    // MARK: - К2: движок бросает invalidResult(Transcript.Word, инв. 0/7) → engineFailure

    /// Вектор К2 дословно: `FakeTranscriptionEngine` бросает `invalidResult` с
    /// `DomainValidationError` для `Transcript.Word`; тестовый сервис отвечает
    /// `.failed(jobId, .invalidResult(error))` по настоящему `NSXPCConnection`.
    private func transcribeWithWordConfidence(_ confidence: Double) async throws -> (code: String, message: String) {
        let engine = FakeTranscriptionEngine()
        engine.forcedResult = {
            _ = try Transcript.Word(startMs: 0, endMs: 100, text: "x", confidence: confidence, original: nil)
            throw PlistSurgeryError.targetNotFound("Word(confidence: \(confidence)) обязан был бросить")
        }
        let fixture = try await readyFixture(service: TestEngineXPCService(transcription: engine))
        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
        } catch TranscriptionServiceError.engineFailure(let code, let message) {
            return (code, message)
        }
        XCTFail("ожидался engineFailure(invalidResult)")
        return ("", "")
    }

    /// Расхождение с перечнем (MEE-370, К2, ответ на macos-14): перечень ждёт `message`,
    /// начинающийся `C-003.Transcript.Word инв. N, confidence:` (сведение C-012 §3.3 —
    /// `message: error.description` вложенного `DomainValidationError`). Клиент же пишет
    /// `"\(engineError)"` всего `EngineError` (`EngineXPCClient+ErrorMapping.swift`,
    /// `outcome(for:expectedJobId:)`), и строка начинается с имени случая `invalidResult(`.
    /// Продовый код MEE-451 не правит — префикс закреплён ожидаемым отказом, остальное
    /// (код, отсутствие составного пути) проверяется строго.
    private func assertK2Message(
        _ message: String, invariant: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        let prefix = "C-003.Transcript.Word инв. \(invariant), confidence:"
        XCTAssertTrue(message.contains(prefix), "вложенная ошибка обязана дойти: \(message)", file: file, line: line)
        XCTAssertFalse(message.contains("segments["), "путь не составной: \(message)", file: file, line: line)
        XCTAssertFalse(message.contains("words["), "путь не составной: \(message)", file: file, line: line)
        XCTExpectFailure("MEE-451: клиент кладёт в message описание EngineError, а не DomainValidationError")
        XCTAssertTrue(message.hasPrefix(prefix), "message: \(message)", file: file, line: line)
    }

    func test_k2_invariant0NanWordConfidenceMapsToEngineFailureInvalidResult() async throws {
        let outcome = try await transcribeWithWordConfidence(.nan)
        XCTAssertEqual(outcome.code, "invalidResult")
        assertK2Message(outcome.message, invariant: 0)
    }

    func test_k2_invariant7OutOfRangeWordConfidenceMapsToEngineFailureInvalidResult() async throws {
        let outcome = try await transcribeWithWordConfidence(1.0000001)
        XCTAssertEqual(outcome.code, "invalidResult")
        assertK2Message(outcome.message, invariant: 7)
    }

    /// К2(ii) байтами ответа: целый кадр `.transcript`, слово с `confidence` вне `0...1` —
    /// клиент сам ловит `DomainValidationError` при разборе, и здесь `message` — ровно
    /// `description` вложенной ошибки (путь §3.2, как К36(ii)). Вектор (i) байтами так не
    /// собрать: `nan` отсекается декодером как `DecodingError` (ступень (в)), это К36(i).
    func test_k2_invariant7ConfidenceInReplyBytesGivesPrefixedMessage() async throws {
        let fixture = try await readyFixture()
        let word = try Transcript.Word(startMs: 0, endMs: 100, text: "x", confidence: 0.5, original: nil)
        let segment = try Transcript.Segment(
            startMs: 0, endMs: 100, channel: .mic, speakerCluster: nil, text: "x",
            textOriginal: nil, textConfidence: 0.5, words: [word]
        )
        let transcript = try Transcript(
            recordingId: UUID(), language: "ru", engine: "fake-engine", modelVersion: "v1",
            createdAt: Date(), segments: [segment], speakers: []
        )
        let reply = EngineReply.transcript(EngineJobId(rawValue: UUID()), transcript)
        let data = try PlistSurgery.data(for: reply, replacing: "<real>0.5</real>", with: "<real>1.5</real>")
        fixture.service.forcedRawResponse = (data: data, error: nil)

        do {
            _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            XCTFail("ожидался engineFailure(invalidResult)")
        } catch TranscriptionServiceError.engineFailure(let code, let message) {
            XCTAssertEqual(code, "invalidResult")
            XCTAssertTrue(message.hasPrefix("C-003.Transcript.Word инв. 7, confidence:"), message)
            XCTAssertFalse(message.contains("segments["), message)
        }
    }

    // MARK: - К15, «сервис → клиент»: пять полей → serviceUnavailable("ответ не разобран: …")

    private static let unrepresentableInteger = "<integer>100000000000000000</integer>"

    private func assertReplyNotParsed(
        _ fixture: XPCFixture, embed: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            if embed {
                _ = try await fixture.client.embed(recordingId: UUID(), startMs: 0, endMs: 1000, profileId: "p1")
            } else {
                _ = try await fixture.client.transcribe(makeSpec()) { _ in }
            }
            XCTFail("ожидался serviceUnavailable", file: file, line: line)
        } catch TranscriptionServiceError.serviceUnavailable(let message) {
            XCTAssertTrue(message.hasPrefix("ответ не разобран: "), message, file: file, line: line)
        } catch {
            XCTFail("неверный исход: \(error)", file: file, line: line)
        }
    }

    /// Кадр `.diarization` с одной репликой (11000…17000, кластер 5) — значения уникальны в
    /// тексте, замена бьёт ровно одно поле. Род кадра для `transcribe` не тот, но до
    /// сверки рода дело не доходит: байты не разбираются раньше.
    private func turnReply(replacing target: String) throws -> Data {
        let turn = try DiarizationResult.Turn(startMs: 11_000, endMs: 17_000, cluster: 5)
        let speaker = try Transcript.Speaker(cluster: 5, embedding: nil, embeddingModelVersion: nil, totalMs: 6_000)
        let result = try DiarizationResult(turns: [turn], speakers: [speaker], modelVersion: "v")
        let reply = EngineReply.diarization(EngineJobId(rawValue: UUID()), result)
        return try PlistSurgery.data(for: reply, replacing: target, with: Self.unrepresentableInteger)
    }

    private func embeddingReply(replacing target: String, with replacement: String) throws -> Data {
        let result = try EmbeddingResult(vector: [0.125, 0.25, 0.5], dimension: 3, modelVersion: "v")
        let reply = EngineReply.embedding(EngineJobId(rawValue: UUID()), result)
        return try PlistSurgery.data(for: reply, replacing: target, with: replacement)
    }

    func test_k15_replyTurnStartMsUnrepresentableGivesReplyNotParsed() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (data: try turnReply(replacing: "<integer>11000</integer>"), error: nil)
        await assertReplyNotParsed(fixture, embed: false)
    }

    func test_k15_replyTurnEndMsUnrepresentableGivesReplyNotParsed() async throws {
        let fixture = try await readyFixture()
        fixture.service.forcedRawResponse = (data: try turnReply(replacing: "<integer>17000</integer>"), error: nil)
        await assertReplyNotParsed(fixture, embed: false)
    }

    /// Кластер 5 стоит и у `Turn`, и у `Speaker`, а `PlistSurgery` меняет все вхождения —
    /// поэтому здесь результат без `speakers`: литерал `5` остаётся только у `Turn.cluster`.
    func test_k15_replyTurnClusterUnrepresentableGivesReplyNotParsed() async throws {
        let fixture = try await readyFixture()
        let turn = try DiarizationResult.Turn(startMs: 11_000, endMs: 17_000, cluster: 5)
        let result = try DiarizationResult(turns: [turn], speakers: [], modelVersion: "v")
        let reply = EngineReply.diarization(EngineJobId(rawValue: UUID()), result)
        let data = try PlistSurgery.data(
            for: reply, replacing: "<integer>5</integer>", with: Self.unrepresentableInteger
        )
        fixture.service.forcedRawResponse = (data: data, error: nil)
        await assertReplyNotParsed(fixture, embed: false)
    }

    func test_k15_replyEmbeddingVectorElementUnrepresentableGivesReplyNotParsed() async throws {
        let fixture = try await readyFixture(embeddingModelId: "emb-1")
        let data = try embeddingReply(replacing: "<real>0.25</real>", with: "<real>1e400</real>")
        fixture.service.forcedRawResponse = (data: data, error: nil)
        await assertReplyNotParsed(fixture, embed: true)
    }

    func test_k15_replyEmbeddingDimensionUnrepresentableGivesReplyNotParsed() async throws {
        let fixture = try await readyFixture(embeddingModelId: "emb-1")
        let data = try embeddingReply(replacing: "<integer>3</integer>", with: Self.unrepresentableInteger)
        fixture.service.forcedRawResponse = (data: data, error: nil)
        await assertReplyNotParsed(fixture, embed: true)
    }
}
