//  К1 (половина transcribe), К2, К3, К4, К5, К12, К13, К14 — C-011 v5 §1, `TranscriptionEngine`.
//  Тексты критериев — MEE-370 (перечень QA), дословно по формулировкам «Вход»/«Ответ».

import XCTest
import DomainCore
import EngineKit

final class TranscriptionEngineTests: XCTestCase {

    // MARK: - К1, К2 (инв. 1; ступень (в) до (б))

    /// К1/К2(i): `confidence == .nan` непредставимо конечным `Double` — ступень (в),
    /// инвариант 0, раньше собственного инварианта 7.
    func test_k1_k2_transcribeWrapsUnrepresentableWordConfidence() async throws {
        let engine = FakeTranscriptionEngine()
        engine.forcedResult = {
            _ = try Transcript.Word(startMs: 0, endMs: 100, text: "x", confidence: .nan, original: nil)
            XCTFail("Word(confidence: .nan) обязан бросить DomainValidationError")
            throw EngineTestSupportError.unreachable
        }
        do {
            _ = try await engine.transcribe(EngineFixtures.transcriptionRequest(), progress: { _ in })
            XCTFail("ожидался EngineError.invalidResult")
        } catch {
            assertInvalidResult(error, invariant: 0, type: "Transcript.Word", path: "confidence")
        }
    }

    /// К2(ii): `confidence == 1.0000001` — конечно, но вне `0...1`, инвариант 7.
    func test_k2_transcribeWrapsOutOfRangeWordConfidence() async throws {
        let engine = FakeTranscriptionEngine()
        engine.forcedResult = {
            _ = try Transcript.Word(startMs: 0, endMs: 100, text: "x", confidence: 1.0000001, original: nil)
            XCTFail("Word(confidence: 1.0000001) обязан бросить DomainValidationError")
            throw EngineTestSupportError.unreachable
        }
        do {
            _ = try await engine.transcribe(EngineFixtures.transcriptionRequest(), progress: { _ in })
            XCTFail("ожидался EngineError.invalidResult")
        } catch {
            assertInvalidResult(error, invariant: 7, type: "Transcript.Word", path: "confidence")
        }
    }

    // MARK: - К3 (инв. 2)

    func test_k3_transcribeRejectsMixedRecordingIds() async throws {
        let other = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let ref1 = try EngineFixtures.audioRef()
        let ref2 = try AudioRef(
            recordingId: other, channel: .mic, fileURL: EngineFixtures.fileURL,
            sampleRate: 48_000, channelCount: 1, offsetMs: 0
        )
        let request = try EngineFixtures.transcriptionRequest(audio: [ref1, ref2])
        let engine = FakeTranscriptionEngine()
        do {
            _ = try await engine.transcribe(request, progress: { _ in })
            XCTFail("ожидался EngineError.unsupportedRequest")
        } catch EngineError.unsupportedRequest {
            // ожидаемо
        } catch {
            XCTFail("неверная ошибка: \(error)")
        }
    }

    func test_k3_transcriptRecordingIdMatchesFirstAudioWhenConsistent() async throws {
        let request = try EngineFixtures.transcriptionRequest()
        let engine = FakeTranscriptionEngine()
        let transcript = try await engine.transcribe(request, progress: { _ in })
        XCTAssertEqual(transcript.recordingId, request.audio[0].recordingId)
    }

    // MARK: - К4 (инв. 3)

    func test_k4_emptyWordsValidWhenTimestampsNotWanted() async throws {
        let request = try EngineFixtures.transcriptionRequest(wantWordTimestamps: false)
        let engine = FakeTranscriptionEngine()
        let transcript = try await engine.transcribe(request, progress: { _ in })
        XCTAssertTrue(transcript.segments.allSatisfy { $0.words.isEmpty })
    }

    /// Движок вправе не отдавать пословные метки, даже если их попросили, — `words`
    /// не обязателен даже при `wantWordTimestamps == true`.
    func test_k4_emptyWordsValidEvenWhenTimestampsWanted() async throws {
        let request = try EngineFixtures.transcriptionRequest(wantWordTimestamps: true)
        let engine = FakeTranscriptionEngine()
        engine.forcedResult = { [engineId = engine.engineId] in
            try Transcript(
                recordingId: request.audio[0].recordingId, language: "en", engine: engineId,
                modelVersion: "v1", createdAt: Date(timeIntervalSince1970: 0),
                segments: [try Transcript.Segment(
                    startMs: 0, endMs: 1_000, channel: .mic, speakerCluster: nil,
                    text: "тихо", textOriginal: nil, textConfidence: nil, words: []
                )],
                speakers: []
            )
        }
        let transcript = try await engine.transcribe(request, progress: { _ in })
        XCTAssertTrue(transcript.segments[0].words.isEmpty, "words пуст даже при wantWordTimestamps == true")
    }

    // MARK: - К5 (инв. 4)

    func test_k5_transcriptStartsAtOffsetPlusInternalEngineTime() async throws {
        let request = try EngineFixtures.transcriptionRequest(
            audio: [try EngineFixtures.audioRef(offsetMs: 5_000)]
        )
        let engine = FakeTranscriptionEngine()
        engine.internalSegmentStartMs = 1_000
        let transcript = try await engine.transcribe(request, progress: { _ in })
        XCTAssertEqual(transcript.segments.first?.startMs, 6_000)
    }

    // MARK: - К12 (инв. 11)

    func test_k12_cancellationDuringWorkThrowsCancelledNotHangOrPartial() async throws {
        let engine = FakeTranscriptionEngine()
        engine.simulatedWorkNanoseconds = 2_000_000_000
        let request = try EngineFixtures.transcriptionRequest()
        let task = Task<Transcript, Error> {
            try await engine.transcribe(request, progress: { _ in })
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("ожидался EngineError.cancelled")
        } catch EngineError.cancelled {
            // ожидаемо: ни зависания, ни частичного результата
        } catch {
            XCTFail("неверная ошибка: \(error)")
        }
    }

    // MARK: - К13 (инв. 12)

    func test_k13_unsupportedLanguageWhenNotInSupportedList() async throws {
        let engine = FakeTranscriptionEngine(supportedLanguages: ["ru", "en"])
        let request = try EngineFixtures.transcriptionRequest(language: "fr")
        do {
            _ = try await engine.transcribe(request, progress: { _ in })
            XCTFail("ожидался EngineError.unsupportedLanguage")
        } catch EngineError.unsupportedLanguage(let language) {
            XCTAssertEqual(language, "fr")
        } catch {
            XCTFail("неверная ошибка: \(error)")
        }
    }

    func test_k13_emptySupportedLanguagesMeansAny() async throws {
        let engine = FakeTranscriptionEngine(supportedLanguages: [])
        let request = try EngineFixtures.transcriptionRequest(language: "fr")
        _ = try await engine.transcribe(request, progress: { _ in })
    }

    func test_k13_nilLanguageAlwaysPasses() async throws {
        let engine = FakeTranscriptionEngine(supportedLanguages: ["ru", "en"])
        let request = try EngineFixtures.transcriptionRequest(language: nil)
        _ = try await engine.transcribe(request, progress: { _ in })
    }

    // MARK: - К14 (инв. 14)

    func test_k14_engineIdIsStableAndCarriedIntoTranscript() async throws {
        let engine = FakeTranscriptionEngine(engineId: "fake-asr-1")
        let request = try EngineFixtures.transcriptionRequest()
        let first = try await engine.transcribe(request, progress: { _ in })
        let second = try await engine.transcribe(request, progress: { _ in })
        XCTAssertEqual(first.engine, "fake-asr-1")
        XCTAssertEqual(second.engine, "fake-asr-1")
        XCTAssertEqual(engine.engineId, "fake-asr-1")
    }
}
