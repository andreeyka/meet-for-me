//  П. 119: ни одна проверка не квадратична по числу элементов.
//
//  Порог тридцатикратный — теперь и по тексту пункта: дельта `Х` перечня MEE-6 переписала
//  п. 119 целиком и взяла тридцать тем же доводом, каким он был взят здесь (ожидаемое
//  значение линейной проверки лежит ВЫШЕ десяти, а не на десяти). Прежняя оговорка про
//  расхождение с текстом пункта снята: расхождения больше нет.
//
//  Два требования той же редакции стоят в тесте отдельными строками, и оба опровержимы:
//  замеряемая валидация обязана завершаться успехом (валидация, отказавшая на замерном
//  входе, не делает работы вовсе — отношение выходит около единицы, и пункт зеленеет по
//  построению), и время малой стороны обязано быть больше нуля БЕЗ подстановки минимального
//  значения вместо измеренного.

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
        //  Эти же четыре вызова утверждают успех замеряемой валидации — отдельно от замера,
        //  как требует п. 119: под `try?` внутри замеряемых замыканий отказ был бы проглочен.
        XCTAssertNoThrow(try bigTranscript.validate())
        XCTAssertNoThrow(try bigManifest.validate())
        XCTAssertNoThrow(try smallTranscript.validate())
        XCTAssertNoThrow(try smallManifest.validate())

        let big = bestOfThree(measureBig)
        let small = bestOfThree(measureSmall)
        //  Утверждение опровержимо: `bestOfThree` отдаёт измеренное время как есть. Прежняя
        //  подстановка `Swift.max(best, 1e-9)` делала эту строку зелёной по построению —
        //  отказать она не могла ни на каком входе.
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
        return best
    }
}
