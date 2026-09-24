//  Возврат РП по MEE-390 (24.09, 20:30 UTC): раздел «Фейк для тестов» C-011 v5 — фейки не
//  просто удовлетворяют throwing-init своего результата, а моделируют зависимость выхода от
//  входа дословно. Ни один из этих тестов не входит в перечень К MEE-370 — это отдельная
//  проверка соответствия самих фейков разделу контракта, а не сквозного протокола.

import XCTest
import DomainCore
import EngineKit

final class FakeEngineFidelityTests: XCTestCase {

    // MARK: - FakeEmbeddingEngine: вектор строится из startMs среза

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let normA = a.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        let normB = b.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return dot / (normA * normB)
    }

    /// Возврат РП по MEE-390 (24.09 21:00 UTC): линейная зависимость `[startMs, startMs+1, …]`
    /// давала косинус 0.9999999 у срезов 1000/2000 — атрибуция (сравнивает по косинусу)
    /// слила бы их в одного говорящего. Порог из самого возврата: у разных срезов < 0.5.
    func test_fakeEmbeddingEngineProducesLowCosineSimilarityForDifferentStartMs() async throws {
        let engine = FakeEmbeddingEngine()
        let first = try await engine.embed(try EngineFixtures.embeddingRequest(startMs: 1_000, endMs: 1_500))
        let second = try await engine.embed(try EngineFixtures.embeddingRequest(startMs: 2_000, endMs: 2_500))
        XCTAssertLessThan(cosine(first.vector, second.vector), 0.5,
                          "разные срезы обязаны давать низкое косинусное сходство")
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
