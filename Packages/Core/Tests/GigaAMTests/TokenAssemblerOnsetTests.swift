//  TokenAssemblerOnsetTests — MEE-513 (IR-157), критерий 2: начало энергии заменяет метку первого токена
//  куска, не являющегося знаком препинания; остальное — как без него (критерий 7 Z2 сохраняется).

import DomainCore
import XCTest
@testable import GigaAM

final class TokenAssemblerOnsetTests: XCTestCase {

    private let marker = "\u{2581}"

    private func chunk(_ pairs: [(String, Double)]) -> RecognizedChunk {
        RecognizedChunk(text: "", tokens: pairs.map(\.0), timestamps: pairs.map(\.1))
    }

    private func assemble(
        _ recognized: RecognizedChunk, onsetMs: Int?, shiftMs: Int = 0, durationMs: Int = 30_000
    ) throws -> [SegmentDraft] {
        try TokenAssembler.assemble(
            recognized, shiftMs: shiftMs, chunkDurationMs: durationMs, channel: .mic, speechOnsetMs: onsetMs
        )
    }

    /// Как в сыром дампе Z6 (MEE-508, тишина 200 мс): первый токен на кадре 0, остальные точные.
    private var dobryDen: RecognizedChunk {
        chunk([
            ("\(marker)Д", 0), ("о", 0.28), ("б", 0.40), ("ры", 0.52), ("й", 0.60), (marker, 0.68), ("д", 0.72),
            ("ень", 0.80), (",", 1.08), ("\(marker)ко", 1.24)
        ])
    }

    func testFirstTokenLabelReplacedOthersUntouched() throws {
        let without = try assemble(dobryDen, onsetMs: nil, shiftMs: 10_000).flatMap(\.words)
        let with = try assemble(dobryDen, onsetMs: 200, shiftMs: 10_000).flatMap(\.words)
        XCTAssertEqual(without.map(\.text), ["Добрый", "день,", "ко"])
        XCTAssertEqual(with.map(\.text), without.map(\.text))
        XCTAssertEqual(without.first?.startMs, 10_000)
        XCTAssertEqual(with.first?.startMs, 10_200)
        XCTAssertEqual(with.first?.endMs, without.first?.endMs)
        XCTAssertEqual(Array(with.dropFirst()), Array(without.dropFirst()))
    }

    func testSecondTokenMsSkipsPunctuationAndBareMarkers() {
        XCTAssertEqual(TokenAssembler.secondTokenMs(in: dobryDen), 280)
        let leading = chunk([(".", 0), (marker, 0.04), ("\(marker)а", 0.08), (",", 0.12), ("\(marker)б", 0.52)])
        XCTAssertEqual(TokenAssembler.secondTokenMs(in: leading), 520)
        XCTAssertNil(TokenAssembler.secondTokenMs(in: chunk([("\(marker)а", 0), (".", 0.12)])))
        XCTAssertNil(TokenAssembler.secondTokenMs(in: chunk([])))
    }

    /// Знак препинания в начале куска метку не несёт: подменяется метка первого слова, знак — к нему.
    func testLeadingPunctuationIsSkipped() throws {
        let recognized = chunk([(".", 0), ("\(marker)при", 0), ("вет", 0.44)])
        let words = try assemble(recognized, onsetMs: 300).flatMap(\.words)
        XCTAssertEqual(words, [WordDraft(startMs: 300, endMs: 480, text: ".привет")])
    }

    /// Первое слово из одного токена: его последний токен и есть первый, поэтому конец — подменённая
    /// метка + 40 мс (от метки модели 0 вышло бы `endMs < startMs`). У слова из нескольких токенов конец
    /// прежний (`testFirstTokenLabelReplacedOthersUntouched`).
    func testSingleTokenFirstWordEndFollowsOnset() throws {
        let recognized = chunk([("\(marker)да", 0), ("\(marker)нет", 0.60), (".", 0.64)])
        let words = try assemble(recognized, onsetMs: 500).flatMap(\.words)
        XCTAssertEqual(words, [
            WordDraft(startMs: 500, endMs: 540, text: "да"),
            WordDraft(startMs: 600, endMs: 640, text: "нет.")
        ])
    }

    /// endMs > startMs у каждого слова и сегмента, слова не пересекаются — при начале у самой второй метки.
    func testCriterion7OfZ2HoldsForAnyOnsetBeforeSecondToken() throws {
        let recognized = chunk([("\(marker)а", 0), ("\(marker)б", 0.04), (".", 0.04), ("\(marker)в", 0.08)])
        for onset in 0...39 {
            let segments = try assemble(recognized, onsetMs: onset, shiftMs: 7_000, durationMs: 120)
            let words = segments.flatMap(\.words)
            XCTAssertEqual(words.first?.startMs, 7_000 + onset)
            for segment in segments {
                XCTAssertGreaterThan(segment.endMs, segment.startMs)
                XCTAssertNoThrow(try segment.makeSegment(cluster: nil, wantWordTimestamps: true))
            }
            for word in words {
                XCTAssertGreaterThan(word.endMs, word.startMs)
            }
            for (word, next) in zip(words, words.dropFirst()) {
                XCTAssertLessThan(word.startMs, next.startMs)
                XCTAssertLessThanOrEqual(word.endMs, next.startMs)
            }
        }
    }

    func testNilOnsetKeepsPreviousBehaviour() throws {
        let recognized = chunk([
            ("\(marker)при", 0.00), ("вет", 0.04), (",", 0.12), ("\(marker)мир", 0.40), (".", 0.44)
        ])
        XCTAssertEqual(try assemble(recognized, onsetMs: nil).flatMap(\.words), [
            WordDraft(startMs: 0, endMs: 80, text: "привет,"),
            WordDraft(startMs: 400, endMs: 440, text: "мир.")
        ])
    }

    /// `wantWordTimestamps == false`: слов нет, а `startMs` сегмента — то же подменённое начало.
    func testWithoutWordTimestampsSegmentStartIsTheSame() throws {
        let segment = try XCTUnwrap(try assemble(dobryDen, onsetMs: 200, shiftMs: 10_000).first)
        let with = try segment.makeSegment(cluster: nil, wantWordTimestamps: true)
        let without = try segment.makeSegment(cluster: nil, wantWordTimestamps: false)
        XCTAssertEqual(without.words, [])
        XCTAssertEqual(without.startMs, 10_200)
        XCTAssertEqual(without.startMs, with.startMs)
        XCTAssertEqual(without.endMs, with.endMs)
    }
}
