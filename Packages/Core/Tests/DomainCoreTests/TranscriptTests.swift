//  Раздел З перечня: инварианты C-003, пп. 55—67.

import XCTest
import DomainCore

final class TranscriptTests: XCTestCase {

    func test_p55_emptyTranscript_isValid() throws {
        let decoded = try decodeTranscript(TranscriptJSON.text())
        XCTAssertEqual(decoded.segments, [])
        XCTAssertEqual(decoded.speakers, [])
    }

    /// Вектор Q3: три сегмента, нарушение между вторым и третьим.
    func test_p56_segmentsMustNotDecrease() throws {
        let segments = "[\(TranscriptJSON.segment(startMs: "0", endMs: "500")), " +
            "\(TranscriptJSON.segment(startMs: "1000", endMs: "1500")), " +
            "\(TranscriptJSON.segment(startMs: "600", endMs: "900"))]"
        assertInvariant(try decodeTranscript(TranscriptJSON.text(segments: segments)),
                        contract: "C-003", type: "Transcript", invariant: 3,
                        path: "segments[2].startMs")
    }

    func test_p56_equalStartsOnDifferentChannels_areAccepted() throws {
        let system = TranscriptJSON.segment(startMs: "0", endMs: "500",
                                            channel: "\"system\"", speakerCluster: "0")
        let pair = "[\(TranscriptJSON.segment(startMs: "0", endMs: "500")), \(system)]"
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            segments: pair, speakers: "[\(TranscriptJSON.speaker())]")))
    }

    func test_p57_zeroLengthSegment_isRejected() throws {
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(startMs: "100", endMs: "100"))]")),
            contract: "C-003", type: "Transcript.Segment", invariant: 3, path: "endMs")
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(startMs: "100", endMs: "50"))]")),
            contract: "C-003", type: "Transcript.Segment", invariant: 3, path: "endMs")
    }

    /// Вектор Q4: границы проверяет сегмент, индекс сегмента в путь не входит.
    func test_p58_wordsMustLieInsideSegment() throws {
        let early = words(third: TranscriptJSON.word(startMs: "-0", endMs: "300"))
        assertInvariant(try decodeTranscript(transcript(words: early, start: "100", end: "900")),
                        contract: "C-003", type: "Transcript.Segment", invariant: 4,
                        path: "words[2].startMs")
        let late = words(third: TranscriptJSON.word(startMs: "700", endMs: "1000"))
        assertInvariant(try decodeTranscript(transcript(words: late, start: "100", end: "900")),
                        contract: "C-003", type: "Transcript.Segment", invariant: 4,
                        path: "words[2].endMs")
        let exact = words(third: TranscriptJSON.word(startMs: "700", endMs: "900"))
        XCTAssertNoThrow(try decodeTranscript(transcript(words: exact, start: "100", end: "900")))
    }

    func test_p59_wordOrderIsCheckedBySegment() throws {
        let unordered = "[\(TranscriptJSON.word(startMs: "0", endMs: "200")), " +
            "\(TranscriptJSON.word(startMs: "300", endMs: "400")), " +
            "\(TranscriptJSON.word(startMs: "100", endMs: "150"))]"
        assertInvariant(try decodeTranscript(transcript(words: unordered, start: "0", end: "500")),
                        contract: "C-003", type: "Transcript.Segment", invariant: 4,
                        path: "words[2].startMs")
    }

    func test_p60_micChannelCarriesNoCluster() throws {
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(speakerCluster: "0"))]",
            speakers: "[\(TranscriptJSON.speaker())]")),
            contract: "C-003", type: "Transcript.Segment", invariant: 5, path: "speakerCluster")
    }

    func test_p61_contentfulSystemTextRequiresCluster() throws {
        for text in ["\"да\"", "\" да \"", "\"\\u00ad\""] {
            assertInvariant(try decodeTranscript(TranscriptJSON.text(
                segments: "[\(TranscriptJSON.segment(channel: "\"system\"", text: text))]")),
                contract: "C-003", type: "Transcript.Segment", invariant: 6, path: "speakerCluster")
        }
        for text in ["\"\"", "\" \"", "\"\\n\\t \"", "\"\\u00a0\""] {
            XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
                segments: "[\(TranscriptJSON.segment(channel: "\"system\"", text: text))]")), text)
        }
    }

    func test_p62_confidenceOutsideRange_isRejected() throws {
        for value in ["1.0000001", "-0.0000001", "-0.5"] {
            assertInvariant(try decodeTranscript(transcript(
                words: "[\(TranscriptJSON.word(confidence: value))]", start: "0", end: "1000")),
                contract: "C-003", type: "Transcript.Word", invariant: 7, path: "confidence")
            assertInvariant(try decodeTranscript(TranscriptJSON.text(
                segments: "[\(TranscriptJSON.segment(textConfidence: value))]")),
                contract: "C-003", type: "Transcript.Segment", invariant: 7, path: "textConfidence")
        }
        for value in ["0.0", "1.0", "null"] {
            XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
                segments: "[\(TranscriptJSON.segment(textConfidence: value))]")), value)
        }
    }

    func test_p63_textConfidenceEqualsMinimum() throws {
        let pair = "[\(TranscriptJSON.word(startMs: "0", endMs: "100", confidence: "0.9")), " +
            "\(TranscriptJSON.word(startMs: "100", endMs: "200", confidence: "0.5"))]"
        assertInvariant(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(endMs: "1000", textConfidence: "0.500000000001", words: pair))]")),
            contract: "C-003", type: "Transcript.Segment", invariant: 8, path: "textConfidence")
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(endMs: "1000", textConfidence: "0.5", words: pair))]")))
    }

    func test_p64_minimumDoesNotApplyWithoutConfidences() throws {
        let mixed = "[\(TranscriptJSON.word(startMs: "0", endMs: "100", confidence: "null")), " +
            "\(TranscriptJSON.word(startMs: "100", endMs: "200", confidence: "0.1"))]"
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(endMs: "1000", textConfidence: "0.9", words: mixed))]")))
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(endMs: "1000", textConfidence: "0.42", words: "[]"))]")))
    }

    func test_p65_clusterInvariant_isReportedByThreeTypes() throws {
        let twoSame = "[\(TranscriptJSON.speaker(cluster: "0")), \(TranscriptJSON.speaker(cluster: "0"))]"
        assertInvariant(try decodeTranscript(TranscriptJSON.text(speakers: twoSame)),
                        contract: "C-003", type: "Transcript", invariant: 9, path: "speakers")
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(cluster: "-1"))]")),
            contract: "C-003", type: "Transcript.Speaker", invariant: 9, path: "cluster")
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(channel: "\"system\"", speakerCluster: "-1"))]",
            speakers: "[\(TranscriptJSON.speaker(cluster: "0"))]")),
            contract: "C-003", type: "Transcript.Segment", invariant: 9, path: "speakerCluster")
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(channel: "\"system\"", speakerCluster: "7"))]")),
            contract: "C-003", type: "Transcript", invariant: 9, path: "segments[0].speakerCluster")
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(cluster: "7"))]")))
    }

    func test_p66_embeddingLengths_areCheckedPerModelVersion() throws {
        let sameVersion = "[\(speaker(cluster: "0", embedding: "[0.1, 0.2]")), " +
            "\(speaker(cluster: "1", embedding: "[0.1]"))]"
        assertInvariant(try decodeTranscript(TranscriptJSON.text(speakers: sameVersion)),
                        contract: "C-003", type: "Transcript", invariant: 11, path: "speakers")
        let differentVersion = "[\(speaker(cluster: "0", embedding: "[0.1, 0.2]")), " +
            "\(speaker(cluster: "1", embedding: "[0.1]", version: "\"emb-v2\""))]"
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(speakers: differentVersion)))
    }

    func test_p67_sameChannelOverlap_isRejected() throws {
        let early = TranscriptJSON.segment(startMs: "0", endMs: "1000",
                                           channel: "\"system\"", speakerCluster: "0")
        let late = TranscriptJSON.segment(startMs: "500", endMs: "1500",
                                          channel: "\"system\"", speakerCluster: "0")
        let segments = "[\(early), \(TranscriptJSON.segment(startMs: "100", endMs: "900")), \(late)]"
        assertInvariant(try decodeTranscript(TranscriptJSON.text(
            segments: segments, speakers: "[\(TranscriptJSON.speaker())]")),
            contract: "C-003", type: "Transcript", invariant: 14, path: "segments[2].startMs")
    }

    func test_p67_crossChannelOverlapAndTouching_areAccepted() throws {
        let system = TranscriptJSON.segment(startMs: "0", endMs: "1000",
                                            channel: "\"system\"", speakerCluster: "0")
        let overlap = "[\(TranscriptJSON.segment(startMs: "0", endMs: "1000")), \(system)]"
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            segments: overlap, speakers: "[\(TranscriptJSON.speaker())]")))
        let touching = "[\(TranscriptJSON.segment(startMs: "0", endMs: "1000")), " +
            "\(TranscriptJSON.segment(startMs: "1000", endMs: "2000"))]"
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(segments: touching)))
    }

    private func words(third: String) -> String {
        "[\(TranscriptJSON.word(startMs: "100", endMs: "200")), " +
        "\(TranscriptJSON.word(startMs: "300", endMs: "400")), \(third)]"
    }

    private func transcript(words: String, start: String, end: String) -> String {
        TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(startMs: start, endMs: end, words: words))]")
    }

    private func speaker(cluster: String, embedding: String,
                         version: String = "\"emb-v1\"") -> String {
        TranscriptJSON.speaker(cluster: cluster, embedding: embedding,
                               embeddingModelVersion: version)
    }
}
