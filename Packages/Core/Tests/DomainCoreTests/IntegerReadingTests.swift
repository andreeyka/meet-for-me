//  Пп. 128, 129, 130: форма литерала, интероперабельный диапазон и граница по типу поля.

import XCTest
import DomainCore

final class IntegerReadingTests: XCTestCase {

    // MARK: - п. 128

    func test_p128_literalFormIsFreeValueIsBounded() throws {
        let track = try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: "4.8e4"))]", isFinalized: "false"))
        XCTAssertEqual(track.tracks.first?.sampleRate, 48_000)
        let totals = try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(totalMs: "1.0"))]"))
        XCTAssertEqual(totals.speakers.first?.totalMs, 1)
        for (value, expected) in [("-0", 0), ("0e0", 0)] {
            let decoded = try decodeManifest(ManifestJSON.text(
                markers: "[\(ManifestJSON.marker(atMs: value))]"))
            XCTAssertEqual(decoded.markers.first?.atMs, expected, value)
        }
        let cluster = try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(cluster: "1e2"))]"))
        XCTAssertEqual(cluster.speakers.first?.cluster, 100)
    }

    /// Прочитано, но отвергнуто инвариантом, а не разбором: именно эта пара отличает
    /// принятое решение от отвергнутого.
    func test_p128_readThenRejectedByInvariant() throws {
        assertInvariant(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(channelCount: "-0"))]", isFinalized: "false")),
            contract: "C-002", type: "RecordingManifest.Track", invariant: 6, path: "channelCount")
        assertInvariant(try decodeManifest(ManifestJSON.text(schemaVersion: "2.0")),
                        contract: "C-002", type: "RecordingManifest", invariant: 1,
                        path: "schemaVersion")
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(schemaVersion: "2.0")))
    }

    func test_p128_nonIntegralLiteralIsBrokenJSON() throws {
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(totalMs: "1.5"))]")), key: "totalMs")
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(atMs: "0.1"))]")), key: "atMs")
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: "47999.5"))]", isFinalized: "false")),
            key: "sampleRate")
        assertCorrupted(try decodeManifest(ManifestJSON.text(schemaVersion: "2.5")),
                        key: "schemaVersion")
    }

    func test_p128_stringIsNotANumber() throws {
        assertTypeMismatch(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: "\"48000\""))]", isFinalized: "false")))
    }

    // MARK: - п. 129

    func test_p129_bothSidesOfInteroperableRange() throws {
        XCTAssertNoThrow(try Transcript.Word(startMs: 9_007_199_254_740_991,
                                             endMs: 9_007_199_254_740_991,
                                             text: "да", confidence: nil, original: nil))
        assertInvariant(try Transcript.Word(startMs: 0, endMs: 1 << 53, text: "да",
                                            confidence: nil, original: nil),
                        contract: "C-003", type: "Transcript.Word", invariant: 0, path: "endMs")
        assertInvariant(try Transcript.Word(startMs: -9_007_199_254_740_992, endMs: 0, text: "да",
                                            confidence: nil, original: nil),
                        contract: "C-003", type: "Transcript.Word", invariant: 0, path: "startMs")
    }

    func test_p129_everyIntegerFieldFromCode() throws {
        assertInvariant(try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                    sampleRate: 1 << 53, channelCount: 1,
                                                    format: "pcm-caf"),
                        contract: "C-002", type: "RecordingManifest.Track", invariant: 0,
                        path: "sampleRate")
        assertInvariant(try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                    sampleRate: 48_000, channelCount: 1 << 53,
                                                    format: "pcm-caf"),
                        contract: "C-002", type: "RecordingManifest.Track", invariant: 0,
                        path: "channelCount")
        assertInvariant(try RecordingManifest.Marker(kind: .pause, atMs: 1 << 53, detail: nil),
                        contract: "C-002", type: "RecordingManifest.Marker", invariant: 0,
                        path: "atMs")
        assertInvariant(try RecordingManifest.InputDeviceSpan(atMs: 1 << 53, present: true,
                                                              name: nil, uid: nil),
                        contract: "C-002", type: "RecordingManifest.InputDeviceSpan",
                        invariant: 0, path: "atMs")
        try assertDiscontinuityFields()
        try assertTranscriptFields()
    }

    private func assertDiscontinuityFields() throws {
        assertInvariant(try RecordingManifest.Discontinuity(atMs: 1 << 53, gapMs: 0,
                                                            scaleErrorMs: 0, reason: .rebuild),
                        contract: "C-002", type: "RecordingManifest.Discontinuity",
                        invariant: 0, path: "atMs")
        assertInvariant(try RecordingManifest.Discontinuity(atMs: 0, gapMs: -(1 << 53),
                                                            scaleErrorMs: 0, reason: .rebuild),
                        contract: "C-002", type: "RecordingManifest.Discontinuity",
                        invariant: 0, path: "gapMs")
        assertInvariant(try RecordingManifest.Discontinuity(atMs: 0, gapMs: 0,
                                                            scaleErrorMs: 1 << 53, reason: .rebuild),
                        contract: "C-002", type: "RecordingManifest.Discontinuity",
                        invariant: 0, path: "scaleErrorMs")
    }

    private func assertTranscriptFields() throws {
        assertInvariant(try Transcript.Segment(startMs: -(1 << 53), endMs: 0, channel: .mic,
                                               speakerCluster: nil, text: "да", textOriginal: nil,
                                               textConfidence: nil, words: []),
                        contract: "C-003", type: "Transcript.Segment", invariant: 0,
                        path: "startMs")
        assertInvariant(try Transcript.Segment(startMs: 0, endMs: 1 << 53, channel: .mic,
                                               speakerCluster: nil, text: "да", textOriginal: nil,
                                               textConfidence: nil, words: []),
                        contract: "C-003", type: "Transcript.Segment", invariant: 0, path: "endMs")
        assertInvariant(try Transcript.Segment(startMs: 0, endMs: 1_000, channel: .system,
                                               speakerCluster: 1 << 53, text: "да",
                                               textOriginal: nil, textConfidence: nil, words: []),
                        contract: "C-003", type: "Transcript.Segment", invariant: 0,
                        path: "speakerCluster")
        assertInvariant(try Transcript.Speaker(cluster: 1 << 53, embedding: nil,
                                               embeddingModelVersion: nil, totalMs: 0),
                        contract: "C-003", type: "Transcript.Speaker", invariant: 0,
                        path: "cluster")
        assertInvariant(try Transcript.Speaker(cluster: 0, embedding: nil,
                                               embeddingModelVersion: nil, totalMs: 1 << 53),
                        contract: "C-003", type: "Transcript.Speaker", invariant: 0,
                        path: "totalMs")
    }

    func test_p129_everyIntegerFieldFromJSON() throws {
        let over = "9007199254740992"
        assertCorrupted(try decodeManifest(ManifestJSON.text(schemaVersion: over)),
                        key: "schemaVersion")
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: over))]", isFinalized: "false")),
            key: "sampleRate")
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(channelCount: over))]", isFinalized: "false")),
            key: "channelCount")
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(atMs: over))]")), key: "atMs")
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            inputDevices: "[\(ManifestJSON.span(atMs: over))]")), key: "atMs")
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            discontinuities: "[\(ManifestJSON.gap(gapMs: over))]")), key: "gapMs")
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            discontinuities: "[\(ManifestJSON.gap(scaleErrorMs: over))]")), key: "scaleErrorMs")
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(schemaVersion: over)),
                        key: "schemaVersion")
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(startMs: over))]")), key: "startMs")
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(endMs: over))]")), key: "endMs")
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(speakerCluster: over))]")), key: "speakerCluster")
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(cluster: over))]")), key: "cluster")
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(totalMs: over))]")), key: "totalMs")
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(words: "[\(TranscriptJSON.word(startMs: over))]"))]")),
            key: "startMs")
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(words: "[\(TranscriptJSON.word(endMs: over))]"))]")),
            key: "endMs")
        for value in ["-9007199254740992", "9007199254740993", "9223372036854775808"] {
            assertCorrupted(try decodeManifest(ManifestJSON.text(
                markers: "[\(ManifestJSON.marker(atMs: value))]")), key: "atMs")
        }
        assertCorruptedByNumberLiteral(try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(atMs: "1e400"))]")), key: "atMs")
    }

    /// Вектор Q27: два негодных поля в одном типе, одно положительное, другое отрицательное.
    func test_p129_firstDeclaredFieldWins() throws {
        assertInvariant(try RecordingManifest.Discontinuity(atMs: 1 << 53, gapMs: -(1 << 53),
                                                            scaleErrorMs: 0, reason: .rebuild),
                        contract: "C-002", type: "RecordingManifest.Discontinuity",
                        invariant: 0, path: "atMs")
    }

    // MARK: - п. 130

    /// Пара `pid` / `atMs` в одном манифесте — единственное место, где разница границ видна.
    func test_p130_boundIsTakenFromDeclaredFieldType() throws {
        let markers = "[\(ManifestJSON.marker(atMs: "2147483648"))]"
        let processes = "[\(ManifestJSON.process(pid: "2147483648"))]"
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            endedAt: "null", markers: markers, capturedProcesses: processes,
            isFinalized: "false")), key: "pid")
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            endedAt: "null", markers: markers,
            capturedProcesses: "[\(ManifestJSON.process(pid: "2147483647"))]",
            isFinalized: "false")))
        for value in ["2147483648", "5000000000", "-2147483649"] {
            assertCorrupted(try decodeManifest(ManifestJSON.text(
                capturedProcesses: "[\(ManifestJSON.process(pid: value))]")), key: "pid")
        }
    }
}
