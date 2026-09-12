//  П. 119: ни одна проверка не квадратична по числу элементов.
//
//  Порог выбран с запасом: линейная проверка даёт отношение около 10, квадратичная — около 100.

import XCTest
import DomainCore

final class PerformanceTests: XCTestCase {

    func test_p119_validationIsNotQuadratic() throws {
        let bigTranscript = try LoadShapes.transcript(segmentCount: 6_000, wordsPerSegment: 10,
                                                      speakerCount: 8, embeddingSize: 256)
        let smallTranscript = try LoadShapes.transcript(segmentCount: 600, wordsPerSegment: 10,
                                                        speakerCount: 8, embeddingSize: 256)
        let bigManifest = try LoadShapes.manifest(discontinuityCount: 10_000)
        let smallManifest = try LoadShapes.manifest(discontinuityCount: 1_000)

        let big = bestOfThree {
            try? bigTranscript.validate()
            try? bigManifest.validate()
        }
        let small = bestOfThree {
            try? smallTranscript.validate()
            try? smallManifest.validate()
        }
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThanOrEqual(big / small, 10.0, "отношение \(big / small) выше десятикратного")
    }

    private func bestOfThree(_ body: () -> Void) -> Double {
        var best = Double.infinity
        for _ in 0..<3 {
            let started = Date()
            body()
            best = Swift.min(best, Date().timeIntervalSince(started))
        }
        return Swift.max(best, 1e-9)
    }
}
