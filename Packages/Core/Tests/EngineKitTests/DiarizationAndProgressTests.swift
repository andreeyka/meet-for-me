//  К1 (половина diarize), К6, К11 — C-011 v5 §1/§5, `DiarizationEngine` и `EngineProgress`.
//  Тексты критериев — MEE-370 (перечень QA), дословно по формулировкам «Вход»/«Ответ».

import XCTest
import DomainCore
import EngineKit

final class DiarizationAndProgressTests: XCTestCase {

    // MARK: - К1 (инв. 1, «то же правило действует для diarize»)

    func test_k1_diarizeWrapsInvalidResultFromSpeaker() async throws {
        let engine = FakeDiarizationEngine()
        engine.forcedResult = {
            _ = try Transcript.Speaker(cluster: 0, embedding: [.infinity],
                                       embeddingModelVersion: "v1", totalMs: 0)
            XCTFail("Speaker(embedding: [.infinity]) обязан бросить DomainValidationError")
            throw EngineTestSupportError.unreachable
        }
        let request = try EngineFixtures.diarizationRequest()
        do {
            _ = try await engine.diarize(request, progress: { _ in })
            XCTFail("ожидался EngineError.invalidResult")
        } catch {
            assertInvalidResult(error, invariant: 0, type: "Transcript.Speaker", path: "embedding[0]")
        }
    }

    // MARK: - К6 (инв. 5)

    func test_k6_diarizeRejectsMicChannel() async throws {
        let engine = FakeDiarizationEngine()
        let request = try EngineFixtures.diarizationRequest(channel: .mic)
        do {
            _ = try await engine.diarize(request, progress: { _ in })
            XCTFail("ожидался EngineError.unsupportedRequest")
        } catch EngineError.unsupportedRequest {
            // ожидаемо
        } catch {
            XCTFail("неверная ошибка: \(error)")
        }
    }

    func test_k6_diarizeAcceptsSystemChannel() async throws {
        let engine = FakeDiarizationEngine()
        let request = try EngineFixtures.diarizationRequest(channel: .system)
        _ = try await engine.diarize(request, progress: { _ in })
    }

    // MARK: - К11 (инв. 10)

    func test_k11_eachStartedStageGetsExactlyOneFinished() async throws {
        let engine = FakeTranscriptionEngine()
        engine.progressScript = [
            .started(stage: .prepare), .advanced(stage: .prepare, fraction: 0.5), .finished(stage: .prepare),
            .started(stage: .asr), .finished(stage: .asr)
        ]
        let collector = ProgressCollector()
        let request = try EngineFixtures.transcriptionRequest()
        _ = try await engine.transcribe(request, progress: { collector.append($0) })

        let events = collector.all
        let started = events.compactMap { event -> EngineStage? in
            guard case .started(let stage) = event else { return nil }
            return stage
        }
        let finished = events.compactMap { event -> EngineStage? in
            guard case .finished(let stage) = event else { return nil }
            return stage
        }
        XCTAssertEqual(started, [.prepare, .asr], "каждый начатый этап отмечен ровно один раз")
        XCTAssertEqual(finished, [.prepare, .asr], "каждый доведённый до конца этап — ровно один раз")
    }

    /// При ошибке или отмене финальное событие этапа не образуется.
    func test_k11_errorAfterStartedNeverPlaysFinishedForThatStage() async throws {
        let engine = FakeTranscriptionEngine()
        engine.progressScript = [.started(stage: .asr)]
        engine.failAfterScript = .runtimeFailure(message: "имитированный сбой")
        let collector = ProgressCollector()
        let request = try EngineFixtures.transcriptionRequest()
        do {
            _ = try await engine.transcribe(request, progress: { collector.append($0) })
            XCTFail("ожидался брошенный EngineError")
        } catch EngineError.runtimeFailure {
            // ожидаемо
        } catch {
            XCTFail("неверная ошибка: \(error)")
        }
        let events = collector.all
        XCTAssertTrue(events.contains(EngineProgress.started(stage: .asr)))
        XCTAssertFalse(events.contains(EngineProgress.finished(stage: .asr)),
                       ".finished(.asr) не образуется — этап не доведён до конца")
    }
}
