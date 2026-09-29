//  ChunkCutterTests — MEE-499 (Z1): критерии 1–7 решения IR-152 на синтетике, без модели и без сети.

import XCTest
@testable import GigaAM

final class ChunkCutterTests: XCTestCase {

    private let rate = ChunkCutter.sampleRate
    private let maxSamples = ChunkCutter.samples(ms: ChunkCutter.maxChunkMs)

    /// Тон 440 Гц амплитудой 0,5 длиной `seconds`, с тишиной в заданных интервалах `[fromMs, toMs)`.
    private func tone(seconds: Double, silences: [(fromMs: Int, toMs: Int)] = []) -> [Float] {
        let count = Int(seconds * Double(rate))
        var result = (0..<count).map { 0.5 * Float(sin(2 * Double.pi * 440 * Double($0) / Double(rate))) }
        for silence in silences {
            let from = min(silence.fromMs * rate / 1_000, count)
            let upper = min(silence.toMs * rate / 1_000, count)
            for index in from..<upper { result[index] = 0 }
        }
        return result
    }

    // Критерий 1
    func testShortWindowIsCutWhole() {
        let window = tone(seconds: 12.34)
        XCTAssertEqual(ChunkCutter.cutLength(window: window, isLast: false), window.count)
        XCTAssertEqual(ChunkCutter.cutLength(window: [], isLast: true), 0)
    }

    func testLastWindowOfExactlyThirtySecondsIsCutWhole() {
        let window = tone(seconds: 30, silences: [(24_850, 25_150)])
        XCTAssertEqual(ChunkCutter.cutLength(window: window, isLast: true), maxSamples)
    }

    // Критерий 2
    func testCutFallsIntoPauseAroundTwentyFiveSeconds() {
        let window = tone(seconds: 30, silences: [(24_850, 25_150)])
        let cutMs = ChunkCutter.cutLength(window: window, isLast: false) * 1_000 / rate
        XCTAssertLessThanOrEqual(abs(cutMs - 25_000), 150)
        XCTAssertGreaterThanOrEqual(cutMs, 24_850)
        XCTAssertLessThanOrEqual(cutMs, 25_150)
    }

    // Критерий 3
    func testLaterOfTwoEqualPausesWins() {
        let window = tone(seconds: 30, silences: [(22_000, 22_200), (27_000, 27_400)])
        let cutMs = ChunkCutter.cutLength(window: window, isLast: false) * 1_000 / rate
        XCTAssertGreaterThanOrEqual(cutMs, 27_000)
        XCTAssertLessThanOrEqual(cutMs, 27_400)
    }

    // Критерий 4
    func testDigitalSilenceGivesThirtySeconds() {
        let window = [Float](repeating: 0, count: maxSamples)
        XCTAssertEqual(ChunkCutter.cutLength(window: window, isLast: false), maxSamples)
    }

    // Критерий 5
    func testLengthIsInRangeAndMultipleOf320() {
        let layouts: [[(fromMs: Int, toMs: Int)]] = [
            [], [(20_000, 20_400)], [(29_600, 30_000)], [(23_017, 23_611)], [(20_000, 30_000)]
        ]
        for silences in layouts {
            let length = ChunkCutter.cutLength(window: tone(seconds: 30, silences: silences), isLast: false)
            XCTAssertGreaterThanOrEqual(length, ChunkCutter.samples(ms: ChunkCutter.minChunkMs))
            XCTAssertLessThanOrEqual(length, maxSamples)
            XCTAssertEqual(length % 320, 0)
        }
    }

    func testContinuousToneCutsAtLatestEqualWindow() {
        // Постоянный тон: энергия окон почти равна, длина всё равно в диапазоне и кратна 320.
        let length = ChunkCutter.cutLength(window: tone(seconds: 30), isLast: false)
        XCTAssertTrue((320_000...480_000).contains(length))
        XCTAssertEqual(length % 320, 0)
    }

    // Критерий 6
    func testCoverageOfSixHundredThirteenSeconds() {
        let seconds = 613.0
        let silences = stride(from: 3_000, to: 613_000, by: 4_700).map { (fromMs: $0, toMs: $0 + 300) }
        let record = tone(seconds: seconds, silences: silences)
        var position = 0
        var chunks: [Range<Int>] = []
        while position < record.count {
            let end = min(position + maxSamples, record.count)
            let length = ChunkCutter.cutLength(window: Array(record[position..<end]), isLast: end == record.count)
            XCTAssertGreaterThan(length, 0)
            chunks.append(position..<(position + length))
            position += length
        }
        XCTAssertEqual(chunks.first?.lowerBound, 0)
        XCTAssertEqual(chunks.last?.upperBound, record.count)
        for (index, chunk) in chunks.enumerated() {
            XCTAssertLessThanOrEqual(chunk.count, maxSamples)
            if index > 0 { XCTAssertEqual(chunk.lowerBound, chunks[index - 1].upperBound) }
        }
        XCTAssertLessThanOrEqual(chunks.count, 31)
    }

    // Критерий 7
    func testIsDeterministic() {
        let window = tone(seconds: 30, silences: [(24_000, 24_300), (26_500, 26_900)])
        XCTAssertEqual(
            ChunkCutter.cutLength(window: window, isLast: false),
            ChunkCutter.cutLength(window: window, isLast: false)
        )
    }
}
