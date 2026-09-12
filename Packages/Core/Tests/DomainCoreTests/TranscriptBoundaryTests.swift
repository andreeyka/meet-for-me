//  Раздел И перечня: границы и мусор из реального движка, пп. 68—79.

import XCTest
import DomainCore

final class TranscriptBoundaryTests: XCTestCase {

    func test_p68_language_isCheckedByShapeNotRegistry() throws {
        for value in ["\"ru\"", "\"en\"", "\"rus\"", "\"ru-RU\"", "\"ru-Cyrl-RU\"", "\"zz\""] {
            XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(language: value)), value)
        }
        for value in ["\"русский\"", "\"RU\"", "\"\"", "\"r\"", "\"ruru\"", "\"ru-\"",
                      "\"ru_RU\"", "\"ru-123456789\""] {
            assertInvariant(try decodeTranscript(TranscriptJSON.text(language: value)),
                            contract: "C-003", type: "Transcript", invariant: 13, path: "language")
        }
    }

    func test_p69_emptyEngineAndModelVersion_areAccepted() throws {
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(engine: "\"\"",
                                                                  modelVersion: "\"\"")))
    }

    func test_p70_negativeSegmentStart_isRejected() throws {
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(startMs: "-1", endMs: "1000"))]")),
            contract: "C-003", type: "Transcript.Segment", invariant: 3, path: "startMs")
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(startMs: "0", endMs: "1000"))]")))
    }

    /// Тот же вход из кода даёт ту же ошибку: значение `-1` представимо, ступень (в) молчит.
    func test_p70_negativeSegmentStart_isSameFromCode() throws {
        assertInvariant(try Transcript.Segment(startMs: -1, endMs: 1_000, channel: .mic,
                                               speakerCluster: nil, text: "речь",
                                               textOriginal: nil, textConfidence: nil, words: []),
                        contract: "C-003", type: "Transcript.Segment", invariant: 3, path: "startMs")
    }

    func test_p71_emptyWordsWithText_isAccepted() throws {
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(text: "\"есть текст\"", words: "[]"))]")))
    }

    func test_p72_zeroLengthWord_isAccepted() throws {
        let zero = "[\(TranscriptJSON.word(startMs: "100", endMs: "100"))]"
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(startMs: "0", endMs: "1000", words: zero))]")))
    }

    func test_p73_overlappingWords_areAccepted() throws {
        let overlapping = "[\(TranscriptJSON.word(startMs: "0", endMs: "300")), " +
            "\(TranscriptJSON.word(startMs: "200", endMs: "500"))]"
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(startMs: "0", endMs: "1000", words: overlapping))]")))
    }

    func test_p74_emptyEmbedding_isRejected() throws {
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(embedding: "[]", embeddingModelVersion: "\"emb-v1\""))]")),
            contract: "C-003", type: "Transcript.Speaker", invariant: 10, path: "embedding")
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker())]")))
    }

    /// Ступень (а) идёт по полям в порядке объявления: `segments` объявлен раньше `speakers`.
    func test_p75_nestedOrder_followsDeclarationOrder() throws {
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(channel: "\"system\"", speakerCluster: "-1"))]",
            speakers: "[\(TranscriptJSON.speaker(cluster: "-1"))]")),
            contract: "C-003", type: "Transcript.Segment", invariant: 9, path: "speakerCluster")
    }

    func test_p76_totalMs_isBoundedOnlyBySign() throws {
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(totalMs: "-1"))]")),
            contract: "C-003", type: "Transcript.Speaker", invariant: 12, path: "totalMs")
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(totalMs: "0"))]")))
    }

    /// `totalMs`, не равный сумме длительностей сегментов своего кластера, — принято.
    func test_p76_totalMsUnrelatedToSegments_isAccepted() throws {
        let segment = TranscriptJSON.segment(startMs: "0", endMs: "1000",
                                             channel: "\"system\"", speakerCluster: "0")
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(segment)]",
            speakers: "[\(TranscriptJSON.speaker(totalMs: "999999"))]")))
    }

    func test_p77_unknownRecordingId_isAccepted() throws {
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            recordingId: "\"00000000-0000-4000-8000-000000000000\"")))
    }

    func test_p78_reprocessingProducesDistinctTranscripts() throws {
        let first = try decodeTranscript(TranscriptJSON.text(engine: "\"gigaam\"",
                                                             modelVersion: "\"v1\""))
        let second = try decodeTranscript(TranscriptJSON.text(engine: "\"parakeet\"",
                                                              modelVersion: "\"v2\""))
        XCTAssertEqual(first.recordingId, second.recordingId)
        XCTAssertNotEqual(first, second)
    }

    /// Транскрипт масштаба трёхчасовой встречи разбирается и кодируется без падения.
    func test_p79_largeTranscript_isHandled() throws {
        let transcript = try LoadShapes.transcript(segmentCount: 6_000, wordsPerSegment: 10,
                                                   speakerCount: 8, embeddingSize: 256)
        let data = try DomainJSON.encode(transcript)
        let back = try DomainJSON.decode(Transcript.self, from: data)
        XCTAssertEqual(back.segments.count, 6_000)
        XCTAssertEqual(back.segments.reduce(0) { $0 + $1.words.count }, 60_000)
    }
}
