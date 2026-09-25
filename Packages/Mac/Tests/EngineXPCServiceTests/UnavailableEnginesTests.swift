//  UnavailableEnginesTests — MEE-438, возврат РП (11:50 UTC): напрямую, в обход XPC — каждая
//  заглушка называет ИМЕННО запрошенную модель (`.modelMissing(modelId:, version:)`), кроме
//  `PostProcessor` при `model == nil`, где назвать нечего (`.runtimeFailure`). Раскрытие уже
//  стоит в заголовке `UnavailableEngines.swift`: ни C-011, ни C-012, ни MEE-370 не называют
//  это соглашение — выбор этой задачи, здесь только проверка, что код делает буквально то,
//  что раскрыто.

import XCTest
import DomainCore
import EngineKit
import EngineXPCService

final class UnavailableEnginesTests: XCTestCase {

    func test_transcriptionThrowsModelMissingNamingRequestedAsrModel() async {
        let engine = UnavailableTranscriptionEngine()
        let model = ServiceFixtures.modelBundle(role: .asr)
        guard let request = try? TranscriptionRequest(
            audio: [try ServiceFixtures.audioRef()], language: nil, wantWordTimestamps: false,
            asrModel: model, vadModel: nil
        ) else { return XCTFail("не удалось построить запрос") }

        do {
            _ = try await engine.transcribe(request) { _ in }
            XCTFail("ожидался modelMissing")
        } catch EngineError.modelMissing(let modelId, let version) {
            XCTAssertEqual(modelId, model.modelId)
            XCTAssertEqual(version, model.version)
        } catch {
            XCTFail("ожидался modelMissing, получено \(error)")
        }
    }

    func test_diarizationThrowsModelMissingNamingRequestedSegmentationModel() async {
        let engine = UnavailableDiarizationEngine()
        let model = ServiceFixtures.modelBundle(role: .diarization)
        guard let request = try? ServiceFixtures.diarizationRequest() else {
            return XCTFail("не удалось построить запрос")
        }

        do {
            _ = try await engine.diarize(request) { _ in }
            XCTFail("ожидался modelMissing")
        } catch EngineError.modelMissing(let modelId, let version) {
            XCTAssertEqual(modelId, model.modelId)
            XCTAssertEqual(version, model.version)
        } catch {
            XCTFail("ожидался modelMissing, получено \(error)")
        }
    }

    func test_embeddingThrowsModelMissingNamingRequestedModel() async {
        let engine = UnavailableEmbeddingEngine()
        let model = ServiceFixtures.modelBundle(role: .embedding)
        guard let audio = try? ServiceFixtures.audioRef(),
              let slice = try? AudioSlice(source: audio, startMs: 0, endMs: 500),
              let request = try? EmbeddingRequest(slice: slice, model: model)
        else { return XCTFail("не удалось построить запрос") }

        do {
            _ = try await engine.embed(request)
            XCTFail("ожидался modelMissing")
        } catch EngineError.modelMissing(let modelId, let version) {
            XCTAssertEqual(modelId, model.modelId)
            XCTAssertEqual(version, model.version)
        } catch {
            XCTFail("ожидался modelMissing, получено \(error)")
        }
    }

    /// `PostProcessRequest.model` НЕОБЯЗАТЕЛЕН (в отличие от трёх других запросов): при
    /// заданной модели — тот же `.modelMissing`, что и у остальных трёх заглушек.
    func test_postProcessThrowsModelMissingWhenModelIsGiven() async {
        let engine = UnavailablePostProcessor()
        // `ModelRole` не называет отдельного случая для постобработки — роль здесь не о чем,
        // кроме того, что `PostProcessRequest.model` вообще задан; любая существующая годится.
        let model = ServiceFixtures.modelBundle(role: .asr)
        guard let transcript = try? Self.makeMinimalTranscript(),
              let request = try? PostProcessRequest(
                transcript: transcript, meetingTitle: nil, attendeeNames: [],
                agendaText: nil, profileId: "p1", model: model
              )
        else { return XCTFail("не удалось построить запрос") }

        do {
            _ = try await engine.process(request) { _ in }
            XCTFail("ожидался modelMissing")
        } catch EngineError.modelMissing(let modelId, let version) {
            XCTAssertEqual(modelId, model.modelId)
            XCTAssertEqual(version, model.version)
        } catch {
            XCTFail("ожидался modelMissing, получено \(error)")
        }
    }

    /// `model == nil` — облачная реализация, своей модели нет (`EngineRequests.swift`):
    /// назвать несуществующую модель нечем, заглушка отказывает `.runtimeFailure`, не
    /// `.modelMissing` с пустыми полями.
    func test_postProcessThrowsRuntimeFailureWhenModelIsNil() async {
        let engine = UnavailablePostProcessor()
        guard let transcript = try? Self.makeMinimalTranscript(),
              let request = try? PostProcessRequest(
                transcript: transcript, meetingTitle: nil, attendeeNames: [],
                agendaText: nil, profileId: "p1", model: nil
              )
        else { return XCTFail("не удалось построить запрос") }

        do {
            _ = try await engine.process(request) { _ in }
            XCTFail("ожидался runtimeFailure")
        } catch EngineError.runtimeFailure {
            // ожидаемо
        } catch {
            XCTFail("ожидался runtimeFailure, получено \(error)")
        }
    }

    private static func makeMinimalTranscript() throws -> Transcript {
        try Transcript(
            recordingId: ServiceFixtures.recordingId, language: "ru", engine: "fake-asr",
            modelVersion: "v1", createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            segments: [], speakers: []
        )
    }
}
