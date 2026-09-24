//  К26, К48 — C-012 инв. 6 (cancel неизвестного/уже завершённого — успешный no-op) и
//  инв. 1 (ровно один финальный `EngineReply` на `jobId`). Тексты критериев — MEE-370
//  (перечень QA), дословно по формулировкам «Вход»/«Ответ».

import XCTest
import DomainCore
import DomainTestKit
import EngineKit

final class LoopbackTransportRepliesTests: XCTestCase {

    private func makeTransport(
        transcription: TranscriptionEngine = FakeTranscriptionEngine(),
        diarization: DiarizationEngine = FakeDiarizationEngine(),
        embedding: EmbeddingEngine = FakeEmbeddingEngine(),
        postProcessor: PostProcessor = FakePostProcessor()
    ) -> LoopbackEngineTransport {
        LoopbackEngineTransport(transcription: transcription, diarization: diarization,
                                embedding: embedding, postProcessor: postProcessor)
    }

    /// Опрос вместо фиксированной паузы: задачи `LoopbackEngineTransport` — независимые
    /// `Task`, у которых нет прямого дескриптора `await` со стороны теста.
    private func waitUntil(
        timeout: TimeInterval = 2, file: StaticString = #filePath, line: UInt = #line,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("условие не наступило вовремя", file: file, line: line)
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    // MARK: - К26 (инв. 6)

    func test_k26_cancelUnknownJobIdIsSuccessfulNoOp() {
        let transport = makeTransport()
        transport.receive(.cancel(EngineJobId(rawValue: UUID())))
        XCTAssertTrue(transport.sentReplies.isEmpty, "ни ошибки, ни ответа")
        XCTAssertTrue(transport.sentProgress.isEmpty)
    }

    func test_k26_cancelAlreadyFinishedJobIdIsSuccessfulNoOp() async throws {
        let transport = makeTransport()
        let jobId = EngineJobId(rawValue: UUID())
        transport.receive(.embed(jobId, try EngineFixtures.embeddingRequest()))
        try await waitUntil { transport.sentReplies.count == 1 }

        transport.receive(.cancel(jobId))
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(transport.sentReplies.count, 1, "второй ответ на тот же jobId не появляется")
    }

    // MARK: - К48 (инв. 1)

    func test_k48_sixRequestsEachProduceExactlyOneMatchingFinalReply() async throws {
        let transport = makeTransport()
        let transcribeJob = EngineJobId(rawValue: UUID())
        let diarizeJob = EngineJobId(rawValue: UUID())
        let embedJob = EngineJobId(rawValue: UUID())
        let postProcessJob = EngineJobId(rawValue: UUID())

        transport.receive(.transcribe(transcribeJob, try EngineFixtures.transcriptionRequest()))
        transport.receive(.diarize(diarizeJob, try EngineFixtures.diarizationRequest()))
        transport.receive(.embed(embedJob, try EngineFixtures.embeddingRequest()))
        transport.receive(.postProcess(
            postProcessJob, try EngineFixtures.postProcessRequest(transcript: TranscriptFixtures.oneOnOne)
        ))
        try await waitUntil { transport.sentReplies.count == 4 }

        func jobId(of reply: EngineReply) -> EngineJobId {
            switch reply {
            case .transcript(let id, _), .diarization(let id, _), .embedding(let id, _),
                 .outputs(let id, _), .cancelled(let id), .failed(let id, _):
                return id
            case .pong:
                XCTFail("ping не запрашивался")
                return EngineJobId(rawValue: UUID())
            }
        }
        let byJob = Dictionary(uniqueKeysWithValues: transport.sentReplies.map { (jobId(of: $0), $0) })

        guard case .transcript = byJob[transcribeJob] else { return XCTFail("ожидался .transcript") }
        guard case .diarization = byJob[diarizeJob] else { return XCTFail("ожидался .diarization") }
        guard case .embedding = byJob[embedJob] else { return XCTFail("ожидался .embedding") }
        guard case .outputs = byJob[postProcessJob] else { return XCTFail("ожидался .outputs") }
        XCTAssertEqual(transport.sentReplies.count, 4, "ровно один финальный ответ на каждый jobId")
    }

    func test_k48_failedTranscribeProducesExactlyOneFailedReply() async throws {
        let transcription = FakeTranscriptionEngine()
        transcription.forcedResult = { throw EngineError.modelMissing(modelId: "m1", version: "1.0") }
        let transport = makeTransport(transcription: transcription)
        let jobId = EngineJobId(rawValue: UUID())
        transport.receive(.transcribe(jobId, try EngineFixtures.transcriptionRequest()))
        try await waitUntil { !transport.sentReplies.isEmpty }

        XCTAssertEqual(transport.sentReplies.count, 1)
        guard case .failed(let id, .modelMissing(let modelId, let version)) = transport.sentReplies[0] else {
            return XCTFail("ожидался .failed(.modelMissing)")
        }
        XCTAssertEqual(id, jobId)
        XCTAssertEqual(modelId, "m1")
        XCTAssertEqual(version, "1.0")
    }

    func test_k48_cancelledTranscribeProducesExactlyOneCancelledReply() async throws {
        let transcription = FakeTranscriptionEngine()
        transcription.simulatedWorkNanoseconds = 500_000_000
        let transport = makeTransport(transcription: transcription)
        let jobId = EngineJobId(rawValue: UUID())
        transport.receive(.transcribe(jobId, try EngineFixtures.transcriptionRequest()))
        try await Task.sleep(nanoseconds: 20_000_000)
        transport.receive(.cancel(jobId))
        try await waitUntil { !transport.sentReplies.isEmpty }

        XCTAssertEqual(transport.sentReplies.count, 1)
        XCTAssertEqual(transport.sentReplies[0], .cancelled(jobId))
    }

    // MARK: - К41 через LoopbackEngineTransport целиком (не напрямую EngineWire)

    /// Возврат РП по MEE-390: К41 обязан проходить через сам `LoopbackEngineTransport`
    /// (`finish` → `normalizingDates` → `encode` → `decode`), не только через прямой вызов
    /// `EngineWire.normalizingDates` — иначе `finish`/`recordProgress` могли бы обходить
    /// провод незамеченно ни одним тестом. Сравнение — с явным ожидаемым значением, не только
    /// "кратно миллисекунде": 1_000.123_456_789 округляется до 1_000.123.
    func test_k41_loopbackTransportRoundsRepliedCreatedAtToNearestMillisecond() async throws {
        let transcription = FakeTranscriptionEngine()
        transcription.forcedResult = {
            try Transcript(
                recordingId: EngineFixtures.recordingId, language: "en", engine: "fake-asr",
                modelVersion: "v1", createdAt: Date(timeIntervalSince1970: 1_000.123_456_789),
                segments: [], speakers: []
            )
        }
        let transport = makeTransport(transcription: transcription)
        let jobId = EngineJobId(rawValue: UUID())
        transport.receive(.transcribe(jobId, try EngineFixtures.transcriptionRequest()))
        try await waitUntil { !transport.sentReplies.isEmpty }

        guard case .transcript(_, let transcript) = transport.sentReplies[0] else {
            return XCTFail("ожидался .transcript")
        }
        XCTAssertEqual(transcript.createdAt.timeIntervalSince1970, 1_000.123, accuracy: 1e-4,
                       "1_000.123_456_789 обязан округлиться до 1_000.123 уже на границе транспорта")
    }

    /// Возврат РП по MEE-390 (24.09 21:00 UTC): дополнительный случай округления вверх —
    /// 1_000.1236 (0.6 доли миллисекунды сверх 1_000.123) обязан округлиться до 1_000.124,
    /// не до 1_000.123 (округление до БЛИЖАЙШЕЙ миллисекунды, не отбрасыванием остатка).
    func test_k41_loopbackTransportRoundsUpToNearestMillisecond() async throws {
        let transcription = FakeTranscriptionEngine()
        transcription.forcedResult = {
            try Transcript(
                recordingId: EngineFixtures.recordingId, language: "en", engine: "fake-asr",
                modelVersion: "v1", createdAt: Date(timeIntervalSince1970: 1_000.1236),
                segments: [], speakers: []
            )
        }
        let transport = makeTransport(transcription: transcription)
        let jobId = EngineJobId(rawValue: UUID())
        transport.receive(.transcribe(jobId, try EngineFixtures.transcriptionRequest()))
        try await waitUntil { !transport.sentReplies.isEmpty }

        guard case .transcript(_, let transcript) = transport.sentReplies[0] else {
            return XCTFail("ожидался .transcript")
        }
        XCTAssertEqual(transcript.createdAt.timeIntervalSince1970, 1_000.124, accuracy: 1e-4,
                       "1_000.1236 обязан округлиться ВВЕРХ до 1_000.124")
    }
}
