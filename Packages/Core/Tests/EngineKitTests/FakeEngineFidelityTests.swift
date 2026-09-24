//  Возврат РП по MEE-390 (24.09, 20:30 UTC): раздел «Фейк для тестов» C-011 v5 — фейки не
//  просто удовлетворяют throwing-init своего результата, а моделируют зависимость выхода от
//  входа дословно. Ни один из этих тестов не входит в перечень К MEE-370 — это отдельная
//  проверка соответствия самих фейков разделу контракта, а не сквозного протокола.

import XCTest
import DomainCore
import EngineKit

final class FakeEngineFidelityTests: XCTestCase {

    // MARK: - FakeEmbeddingEngine: вектор строится из startMs среза

    func test_fakeEmbeddingEngineProducesDifferentVectorsForDifferentStartMs() async throws {
        let engine = FakeEmbeddingEngine()
        let first = try await engine.embed(try EngineFixtures.embeddingRequest(startMs: 0, endMs: 500))
        let second = try await engine.embed(try EngineFixtures.embeddingRequest(startMs: 1_000, endMs: 1_500))
        XCTAssertNotEqual(first.vector, second.vector, "разные срезы обязаны давать разные векторы")
    }

    func test_fakeEmbeddingEngineIsDeterministicForSameStartMs() async throws {
        let engine = FakeEmbeddingEngine()
        let first = try await engine.embed(try EngineFixtures.embeddingRequest(startMs: 700, endMs: 900))
        let second = try await engine.embed(try EngineFixtures.embeddingRequest(startMs: 700, endMs: 1_100))
        XCTAssertEqual(first.vector, second.vector, "один и тот же startMs — один и тот же вектор")
    }

    // MARK: - FakeDiarizationEngine: N равных интервалов по expectedSpeakers

    func test_fakeDiarizationEngineSplitsChannelIntoExpectedSpeakerCount() async throws {
        let engine = FakeDiarizationEngine()
        engine.totalDurationMs = 900
        let request = try EngineFixtures.diarizationRequest(expectedSpeakers: 3)
        let result = try await engine.diarize(request, progress: { _ in })

        XCTAssertEqual(result.turns.count, 3)
        XCTAssertEqual(result.speakers.count, 3)
        XCTAssertEqual(Set(result.turns.map(\.cluster)), Set(0..<3))
        XCTAssertEqual(result.turns.map(\.startMs).sorted(), [0, 300, 600])
        XCTAssertEqual(result.turns.map(\.endMs).sorted(), [300, 600, 900])
    }

    func test_fakeDiarizationEngineDefaultsToOneClusterWhenExpectedSpeakersIsNil() async throws {
        let engine = FakeDiarizationEngine()
        let request = try EngineFixtures.diarizationRequest(expectedSpeakers: nil)
        let result = try await engine.diarize(request, progress: { _ in })

        XCTAssertEqual(result.turns.count, 1)
        XCTAssertEqual(result.speakers.count, 1)
        XCTAssertEqual(result.turns[0].cluster, 0)
        XCTAssertEqual(result.turns[0].startMs, 0)
        XCTAssertEqual(result.turns[0].endMs, engine.totalDurationMs)
    }
}
