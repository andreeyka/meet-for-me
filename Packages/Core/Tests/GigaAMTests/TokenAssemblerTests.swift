//  TokenAssemblerTests — MEE-500 (Z2): критерии 1–10 решения IR-152, без модели и без сети.

import DomainCore
import XCTest
@testable import GigaAM

final class TokenAssemblerTests: XCTestCase {

    private let marker = "\u{2581}"

    private func chunk(_ pairs: [(String, Double)]) -> RecognizedChunk {
        RecognizedChunk(text: "", tokens: pairs.map(\.0), timestamps: pairs.map(\.1))
    }

    private func assemble(
        _ recognized: RecognizedChunk, shiftMs: Int = 0, durationMs: Int = 30_000
    ) throws -> [SegmentDraft] {
        try TokenAssembler.assemble(recognized, shiftMs: shiftMs, chunkDurationMs: durationMs, channel: .mic)
    }

    private var helloWorld: RecognizedChunk {
        chunk([("\(marker)при", 0.00), ("вет", 0.04), (",", 0.12), ("\(marker)мир", 0.40), (".", 0.44)])
    }

    // Критерий 1
    func testHelloWorldGivesTwoWordsAndOneSegment() throws {
        let segments = try assemble(helloWorld)
        XCTAssertEqual(segments.count, 1)
        let segment = try XCTUnwrap(segments.first)
        XCTAssertEqual(segment.words, [
            WordDraft(startMs: 0, endMs: 80, text: "привет,"),
            WordDraft(startMs: 400, endMs: 440, text: "мир.")
        ])
        XCTAssertEqual(segment.text, "привет, мир.")
        XCTAssertEqual(segment.startMs, 0)
        XCTAssertEqual(segment.endMs, 440)
    }

    // Критерий 2
    func testPauseOfTwoSecondsStartsNewSegment() throws {
        let recognized = chunk([("\(marker)да", 0.00), ("\(marker)нет", 2.04)])
        // конец «да» = 0 + 40 = 40 мс, начало «нет» = 2040 мс: пауза ровно 2000 мс
        XCTAssertEqual(try assemble(recognized).map(\.text), ["да", "нет"])
        let shorter = chunk([("\(marker)да", 0.00), ("\(marker)нет", 2.00)])
        XCTAssertEqual(try assemble(shorter).map(\.text), ["да нет"])
    }

    // Критерий 3
    func testPunctuationAtChunkStartGluesToNextWord() throws {
        let recognized = chunk([(".", 0.00), ("\(marker)при", 0.20), ("вет", 0.24)])
        let segments = try assemble(recognized)
        XCTAssertEqual(segments.map(\.text), [".привет"])
        XCTAssertEqual(segments.first?.startMs, 200)
        XCTAssertEqual(segments.first?.endMs, 280)
    }

    // Критерий 4
    func testEmptyInputGivesNoSegments() throws {
        XCTAssertEqual(try assemble(chunk([])), [])
        XCTAssertEqual(try assemble(chunk([(".", 0.0), (",", 0.04)])), [])
        XCTAssertEqual(try assemble(chunk([(marker, 0.0)])), [])
    }

    // Критерий 5
    func testShiftsAreAdded() throws {
        let segments = try assemble(helloWorld, shiftMs: 30_000 + 1_500)
        XCTAssertEqual(segments.first?.startMs, 31_500)
        XCTAssertEqual(segments.first?.endMs, 31_940)
        XCTAssertEqual(segments.first?.words.map(\.startMs), [31_500, 31_900])
        XCTAssertEqual(segments.first?.words.map(\.endMs), [31_580, 31_940])
    }

    // Критерий 6
    func testLabelsAreRounded() throws {
        XCTAssertEqual(TokenAssembler.label(0.0404), 40)
        XCTAssertEqual(TokenAssembler.label(0.0406), 41)
        XCTAssertEqual(TokenAssembler.label(0.12), 120)
        let segments = try assemble(chunk([("\(marker)а", 0.0404), ("\(marker)б", 0.1206)]))
        XCTAssertEqual(segments.first?.words.map(\.startMs), [40, 121])
    }

    // Критерий 7
    func testOrderAndSegmentInitAccepts() throws {
        // метки не по порядку и совпадающие: порядок восстанавливается, значения проходят Segment.init
        let recognized = chunk([
            ("\(marker)а", 0.20), ("\(marker)б", 0.20), ("\(marker)в", 0.16), ("\(marker)г", 0.24), (".", 0.28)
        ])
        let segments = try assemble(recognized)
        for segment in segments {
            let built = try segment.makeSegment(cluster: nil, wantWordTimestamps: true)
            XCTAssertGreaterThan(built.endMs, built.startMs)
            for (word, next) in zip(built.words, built.words.dropFirst()) {
                XCTAssertLessThanOrEqual(word.startMs, next.startMs)
                XCTAssertLessThanOrEqual(word.endMs, next.startMs)
            }
        }
    }

    func testMismatchedLengthsThrow() {
        let bad = RecognizedChunk(text: "", tokens: ["a"], timestamps: [])
        XCTAssertThrowsError(try assemble(bad)) {
            XCTAssertEqual($0 as? TokenAssembler.Failure, .lengthMismatch(tokens: 1, timestamps: 0))
        }
    }

    // Критерий 8
    func testWithoutWordTimestampsWordsAreEmptyAndTextSame() throws {
        let segment = try XCTUnwrap(try assemble(helloWorld).first)
        let with = try segment.makeSegment(cluster: nil, wantWordTimestamps: true)
        let without = try segment.makeSegment(cluster: nil, wantWordTimestamps: false)
        XCTAssertEqual(without.words, [])
        XCTAssertEqual(with.words.count, 2)
        XCTAssertEqual(without.text, with.text)
        XCTAssertNil(with.textConfidence)
        XCTAssertNil(with.words.first?.confidence)
    }

    // Критерий 9
    func testSentenceAcrossChunkBoundaryGivesTwoNonOverlappingSegments() throws {
        // первый кусок 25 с, последнее слово на кадре 24,96 с: 24 960 + 40 = 25 000
        let first = chunk([("\(marker)мы", 24.88), ("\(marker)идём", 24.96)])
        // второй кусок начинается сразу после разреза
        let second = chunk([("\(marker)домой", 0.00), (".", 0.12)])
        let head = try assemble(first, shiftMs: 0, durationMs: 24_980)
        let tail = try assemble(second, shiftMs: 24_980, durationMs: 5_000)
        XCTAssertEqual(head.count, 1)
        XCTAssertEqual(tail.count, 1)
        let lastEnd = try XCTUnwrap(head.last?.endMs)
        let nextStart = try XCTUnwrap(tail.first?.startMs)
        XCTAssertLessThanOrEqual(lastEnd, nextStart)
        XCTAssertNoThrow(try head[0].makeSegment(cluster: nil, wantWordTimestamps: true))
        XCTAssertNoThrow(try tail[0].makeSegment(cluster: nil, wantWordTimestamps: true))
    }

    // Критерий 10
    func testSegmentTextHasSingleSpacesAndNoEdgeSpaces() throws {
        let recognized = chunk([
            (marker, 0.00), ("\(marker)а", 0.04), (marker, 0.08), ("\(marker)б", 0.12), (marker, 0.16)
        ])
        let segments = try assemble(recognized)
        XCTAssertEqual(segments.map(\.text), ["а б"])
        for word in segments.flatMap(\.words) {
            XCTAssertEqual(word.text, word.text.trimmingCharacters(in: .whitespaces))
            XCTAssertFalse(word.text.contains(" "))
        }
    }

    func testSentenceTerminatorsSplitSegments() throws {
        let recognized = chunk([
            ("\(marker)а", 0.0), ("?", 0.04), ("\(marker)б", 0.12), ("!", 0.16), ("\(marker)в", 0.24), ("…", 0.28),
            ("\(marker)г", 0.36)
        ])
        XCTAssertEqual(try assemble(recognized).map(\.text), ["а?", "б!", "в…", "г"])
    }
}
