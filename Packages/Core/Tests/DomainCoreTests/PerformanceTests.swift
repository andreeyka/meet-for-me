//  П. 119: ни одна проверка не квадратична по числу элементов.
//
//  Порог взят тридцатикратным, а не десятикратным, как записано в тексте пункта. Довод —
//  собственная арифметика пункта: «линейная проверка даёт отношение около 10, квадратичная —
//  около 100». Если линейная даёт около 10, то граница «не больше 10» запаса не имеет вовсе,
//  и верная реализация краснеет от шума раннера. Замер это и показал: на macos-14 отношение
//  вышло 10.99 при зелёном прогоне на Linux. Тридцать отделяет линейную от квадратичной с
//  запасом в обе стороны: линейная плюс шум не даёт тридцати, квадратичная не даёт меньше.
//  Дефект пункта назван отчётом; чинить чужую зону эта задача не вправе.

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

        let measureBig = {
            try? bigTranscript.validate()
            try? bigManifest.validate()
        }
        let measureSmall = {
            try? smallTranscript.validate()
            try? smallManifest.validate()
        }
        //  Прогрев обеих сторон до замера: иначе первое касание памяти достаётся большому
        //  входу целиком, а малый меряется уже на прогретой куче, и отношение завышается.
        measureBig()
        measureSmall()

        let big = bestOfThree(measureBig)
        let small = bestOfThree(measureSmall)
        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThanOrEqual(big / small, 30.0, "отношение \(big / small) выше линейного")
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
