//  Инварианты, появившиеся в C-002 v2: пп. 115, 116, 117, 118, 120.

import XCTest
import DomainCore

final class ManifestSpansTests: XCTestCase {

    func test_p115_inputDevices_haveTwoHalvesAndTwoTypes() throws {
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(inputDevices: "[]")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            inputDevices: "[\(ManifestJSON.span(atMs: "0"))]")))
        let three = "[\(ManifestJSON.span(atMs: "0")), \(ManifestJSON.span(atMs: "5000")), " +
            "\(ManifestJSON.span(atMs: "9000"))]"
        let changes = "[\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "5000")), " +
            "\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "9000"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: changes,
                                                              inputDevices: three)))

        assertInvariant(try decodeManifest(ManifestJSON.text(
            inputDevices: "[\(ManifestJSON.span(atMs: "-5"))]")),
            contract: "C-002", type: "RecordingManifest.InputDeviceSpan", invariant: 9,
            path: "atMs")

        let late = "[\(ManifestJSON.span(atMs: "1000")), \(ManifestJSON.span(atMs: "5000"))]"
        let lateMarkers = "[\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "1000")), " +
            "\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "5000"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: lateMarkers,
                                                             inputDevices: late)),
                        contract: "C-002", type: "RecordingManifest", invariant: 9,
                        path: "inputDevices[0].atMs")

        let equal = "[\(ManifestJSON.span(atMs: "0")), \(ManifestJSON.span(atMs: "5000")), " +
            "\(ManifestJSON.span(atMs: "5000"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: changes, inputDevices: equal)),
                        contract: "C-002", type: "RecordingManifest", invariant: 9,
                        path: "inputDevices[2].atMs")

        let falling = "[\(ManifestJSON.span(atMs: "0")), \(ManifestJSON.span(atMs: "5000")), " +
            "\(ManifestJSON.span(atMs: "3000"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: changes,
                                                             inputDevices: falling)),
                        contract: "C-002", type: "RecordingManifest", invariant: 9,
                        path: "inputDevices[2].atMs")
    }

    /// Пара «нестрогий инв. 8 против строгого инв. 9»: без неё реализация с одной общей
    /// проверкой на два массива остаётся зелёной.
    func test_p115_equalTimesAreAcceptedForMarkersAndRejectedForSpans() throws {
        let markers = "[\(ManifestJSON.marker(kind: "\"sleep\"", atMs: "5000")), " +
            "\(ManifestJSON.marker(kind: "\"wake\"", atMs: "5000"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: markers)))
        let spans = "[\(ManifestJSON.span(atMs: "0")), \(ManifestJSON.span(atMs: "0"))]"
        XCTAssertEqual(errorFields(try decodeManifest(ManifestJSON.text(inputDevices: spans)))?
                        .invariant, 9)
    }

    func test_p116_deviceCorrespondence_isCheckedBothWays() throws {
        let spans = "[\(ManifestJSON.span(atMs: "0")), \(ManifestJSON.span(atMs: "5000"))]"
        let marker = "[\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "5000"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: marker,
                                                              inputDevices: spans)))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            inputDevices: "[\(ManifestJSON.span(atMs: "0"))]")))

        let orphanMarker = "[\(ManifestJSON.marker(kind: "\"sleep\"", atMs: "0")), " +
            "\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "5000"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(
            markers: orphanMarker, inputDevices: "[\(ManifestJSON.span(atMs: "0"))]")),
            contract: "C-002", type: "RecordingManifest", invariant: 10, path: "markers[1].atMs")

        assertInvariant(try decodeManifest(ManifestJSON.text(markers: "[]", inputDevices: spans)),
                        contract: "C-002", type: "RecordingManifest", invariant: 10,
                        path: "inputDevices[1].atMs")

        let nearMiss = "[\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "4999"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: nearMiss,
                                                             inputDevices: spans)),
                        contract: "C-002", type: "RecordingManifest", invariant: 10,
                        path: "markers[0].atMs")
    }

    /// Инвариант 10 биекцией не является: дубль маркера его не нарушает.
    func test_p116_duplicateDeviceChangedMarkers_areAccepted() throws {
        let spans = "[\(ManifestJSON.span(atMs: "0")), \(ManifestJSON.span(atMs: "5000"))]"
        let markers = "[\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "5000")), " +
            "\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "5000"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: markers,
                                                              inputDevices: spans)))
    }

    /// Тройка в одном тесте: один номер инварианта, два типа, три пути.
    func test_p117_wordDurationIsCheckedByWord() throws {
        let word = TranscriptJSON.word(startMs: "200", endMs: "100")
        assertInvariant(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(startMs: "0", endMs: "1000", words: "[\(word)]"))]")),
            contract: "C-003", type: "Transcript.Word", invariant: 4, path: "endMs")

        let unordered = "[\(TranscriptJSON.word(startMs: "300", endMs: "400")), " +
            "\(TranscriptJSON.word(startMs: "350", endMs: "450")), " +
            "\(TranscriptJSON.word(startMs: "100", endMs: "150"))]"
        assertInvariant(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(startMs: "0", endMs: "1000", words: unordered))]")),
            contract: "C-003", type: "Transcript.Segment", invariant: 4, path: "words[2].startMs")

        let outside = "[\(TranscriptJSON.word(startMs: "100", endMs: "200")), " +
            "\(TranscriptJSON.word(startMs: "300", endMs: "400")), " +
            "\(TranscriptJSON.word(startMs: "500", endMs: "2000"))]"
        assertInvariant(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(startMs: "0", endMs: "1000", words: outside))]")),
            contract: "C-003", type: "Transcript.Segment", invariant: 4, path: "words[2].endMs")
    }

    func test_p118_embeddingAndVersion_comeOnlyAsAPair() throws {
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker())]")))
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(speakers:
            "[\(TranscriptJSON.speaker(embedding: "[0.1]", embeddingModelVersion: "\"v1\""))]")))
        assertInvariant(try decodeTranscript(TranscriptJSON.text(speakers:
            "[\(TranscriptJSON.speaker(embedding: "[0.1]"))]")),
            contract: "C-003", type: "Transcript.Speaker", invariant: 10, path: "embedding")
        assertInvariant(try decodeTranscript(TranscriptJSON.text(speakers:
            "[\(TranscriptJSON.speaker(embeddingModelVersion: "\"v1\""))]")),
            contract: "C-003", type: "Transcript.Speaker", invariant: 10,
            path: "embeddingModelVersion")
    }

    /// Пара «`confidence` → 0 и `embedding` → 0» в одном тесте: обе половины дают `invariant = 0`.
    func test_p118_nonFiniteElementsGiveRepresentabilityError() throws {
        assertInvariant(try Transcript.Speaker(cluster: 0, embedding: [0.1, .infinity, 0.3],
                                               embeddingModelVersion: "v1", totalMs: 0),
                        contract: "C-003", type: "Transcript.Speaker", invariant: 0,
                        path: "embedding[1]")
        for value in [-Float.infinity, Float.nan] {
            assertInvariant(try Transcript.Speaker(cluster: 0, embedding: [value, 0.3],
                                                   embeddingModelVersion: "v1", totalMs: 0),
                            contract: "C-003", type: "Transcript.Speaker", invariant: 0,
                            path: "embedding[0]")
        }
        assertInvariant(try Transcript.Word(startMs: 0, endMs: 1, text: "да",
                                            confidence: .nan, original: nil),
                        contract: "C-003", type: "Transcript.Word", invariant: 0,
                        path: "confidence")
    }

    /// Индекс элемента массива из JSON не обещан: в `codingPath` стоит имя ключа.
    func test_p118_jsonGivesKeyNameWithoutIndex() throws {
        let path = corruptedPath(try decodeTranscript(TranscriptJSON.text(speakers:
            "[\(TranscriptJSON.speaker(embedding: "[0.1, 1e400, 0.3]", embeddingModelVersion: "\"v1\""))]")))
        XCTAssertEqual(path.last, "embedding")
        XCTAssertFalse(path.contains("1"))
    }

    func test_p120_orderOfEqualKeysIsData() throws {
        let direct = "[\(ManifestJSON.marker(kind: "\"sleep\"", atMs: "5000")), " +
            "\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "5000"))]"
        let swapped = "[\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "5000")), " +
            "\(ManifestJSON.marker(kind: "\"sleep\"", atMs: "5000"))]"
        let gaps = "[\(ManifestJSON.gap(atMs: "5000"))]"
        let first = try decodeManifest(ManifestJSON.text(markers: direct, discontinuities: gaps))
        let second = try decodeManifest(ManifestJSON.text(markers: swapped, discontinuities: gaps))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try DomainJSON.decode(RecordingManifest.self,
                                             from: DomainJSON.encode(first)), first)
        XCTAssertEqual(try DomainJSON.decode(RecordingManifest.self,
                                             from: DomainJSON.encode(second)), second)

        let segments = "[\(TranscriptJSON.segment(startMs: "0", endMs: "500")), " +
            "\(TranscriptJSON.segment(startMs: "0", endMs: "500", channel: "\"system\"", speakerCluster: "0"))]"
        let reversed = "[\(TranscriptJSON.segment(startMs: "0", endMs: "500", channel: "\"system\"", speakerCluster: "0")), " +
            "\(TranscriptJSON.segment(startMs: "0", endMs: "500"))]"
        let speakers = "[\(TranscriptJSON.speaker())]"
        let straight = try decodeTranscript(TranscriptJSON.text(segments: segments,
                                                                speakers: speakers))
        let flipped = try decodeTranscript(TranscriptJSON.text(segments: reversed,
                                                               speakers: speakers))
        XCTAssertNotEqual(straight, flipped)
    }
}
