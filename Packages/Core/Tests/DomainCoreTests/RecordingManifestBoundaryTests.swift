//  Раздел Ж перечня: границы и мусор C-002, пп. 46—54.

import XCTest
import DomainCore

final class RecordingManifestBoundaryTests: XCTestCase {

    func test_p46_enumsWithAndWithoutUnknown_behaveOppositely() throws {
        let markers = "[\(ManifestJSON.marker(kind: "\"thermalThrottle\"", atMs: "10")), " +
            "\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "20"))]"
        let gaps = "[\(ManifestJSON.gap(atMs: "20", reason: "\"gpuReset\""))]"
        let decoded = try decodeManifest(ManifestJSON.text(markers: markers, discontinuities: gaps))
        XCTAssertEqual(decoded.markers.first?.kind, .unknown)
        XCTAssertEqual(decoded.markers.last?.kind, .discontinuity)
        XCTAssertEqual(decoded.discontinuities.first?.reason, .unknown)

        let tracks = "[\(ManifestJSON.track(channel: "\"bluetooth\"")), " +
            "\(ManifestJSON.track(channel: "\"system\"", fileName: "\"s.m4a\""))]"
        XCTAssertThrowsError(try decodeManifest(ManifestJSON.text(tracks: tracks))) { error in
            XCTAssertTrue(error is DecodingError, "ожидался отказ разбора, получено \(error)")
        }
    }

    func test_p47_fileName_mustBeSinglePathComponent() throws {
        let rejected = ["\"../../db.sqlite\"", "\"/tmp/x.caf\"", "\"a/b.caf\"", "\"a\\\\b.caf\"",
                        "\"\"", "\".\"", "\"..\"", "\".hidden.caf\"", "\"a\\tb.caf\""]
        for value in rejected {
            assertInvariant(try decodeManifest(ManifestJSON.text(
                tracks: "[\(ManifestJSON.track(fileName: value))]", isFinalized: "false")),
                contract: "C-002", type: "RecordingManifest.Track", invariant: 3, path: "fileName")
        }
        for value in ["\"mic.caf\"", "\"mic 1.caf\"", "\"запись-микрофон.caf\""] {
            XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
                tracks: "[\(ManifestJSON.track(fileName: value))]", isFinalized: "false")), value)
        }
    }

    /// Граница длины считается в байтах UTF-8, а не в символах.
    func test_p47_fileNameLength_isCountedInBytes() throws {
        let ascii255 = String(repeating: "a", count: 255)
        let ascii256 = String(repeating: "a", count: 256)
        let cyrillic200 = String(repeating: "я", count: 200)
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(fileName: "\"\(ascii255)\""))]", isFinalized: "false")))
        for value in [ascii256, cyrillic200] {
            assertInvariant(try decodeManifest(ManifestJSON.text(
                tracks: "[\(ManifestJSON.track(fileName: "\"\(value)\""))]", isFinalized: "false")),
                contract: "C-002", type: "RecordingManifest.Track", invariant: 3, path: "fileName")
        }
    }

    func test_p48_duplicateFileName_isRejected() throws {
        let tracks = "[\(ManifestJSON.track()), " +
            "\(ManifestJSON.track(channel: "\"system\"", channelCount: "2"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(tracks: tracks)),
                        contract: "C-002", type: "RecordingManifest", invariant: 4, path: "tracks")
    }

    func test_p49_meetingId_isUnconstrained() throws {
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(meetingId: "null")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            meetingId: "\"\(ManifestJSON.identifier)\"")))
    }

    func test_p50_markerBeyondDuration_isRejected() throws {
        let inside = "[\(ManifestJSON.marker(atMs: "0")), \(ManifestJSON.marker(atMs: "3600000"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: inside)))
        let outside = "[\(ManifestJSON.marker(atMs: "0")), \(ManifestJSON.marker(atMs: "3600001"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: outside)),
                        contract: "C-002", type: "RecordingManifest", invariant: 11,
                        path: "markers[1].atMs")
        let spans = "[\(ManifestJSON.span(atMs: "0")), \(ManifestJSON.span(atMs: "3600001"))]"
        let changed = "[\(ManifestJSON.marker(kind: "\"deviceChanged\"", atMs: "3600001"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: changed, inputDevices: spans)),
                        contract: "C-002", type: "RecordingManifest", invariant: 11,
                        path: "markers[0].atMs")
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            endedAt: "null", markers: "[\(ManifestJSON.marker(atMs: "999999999"))]",
            isFinalized: "false")))
    }

    /// Формула `durationMs` округляет к ближайшему: `floor` и `ceil` расходятся только здесь.
    func test_p50_durationFormula_roundsToNearest() throws {
        let started = Date(timeIntervalSince1970: 1_789_113_600)
        let ended = Date(timeIntervalSince1970: 1_789_113_601.0004)
        XCTAssertNoThrow(try manifest(started: started, ended: ended, markerAtMs: 1_000))
        assertInvariant(try manifest(started: started, ended: ended, markerAtMs: 1_001),
                        contract: "C-002", type: "RecordingManifest", invariant: 11,
                        path: "markers[0].atMs")
    }

    func test_p51_capturedProcesses_acceptGarbagePid() throws {
        for value in ["0", "-1", "2147483647", "-2147483648"] {
            XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
                capturedProcesses: "[\(ManifestJSON.process(pid: value))]")), value)
        }
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            capturedProcesses: "[\(ManifestJSON.process(bundleId: "null", executableName: "null"))]")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(capturedProcesses: "[]")))
        for value in ["2147483648", "5000000000", "-2147483649"] {
            assertCorrupted(try decodeManifest(ManifestJSON.text(
                capturedProcesses: "[\(ManifestJSON.process(pid: value))]")), key: "pid")
        }
    }

    func test_p51_emptyStringIsNotAValue() throws {
        assertInvariant(try decodeManifest(ManifestJSON.text(
            capturedProcesses: "[\(ManifestJSON.process(bundleId: "\"\""))]")),
            contract: "C-002", type: "RecordingManifest.CapturedProcess", invariant: 16,
            path: "bundleId")
        assertInvariant(try decodeManifest(ManifestJSON.text(
            capturedProcesses: "[\(ManifestJSON.process(executableName: "\"\""))]")),
            contract: "C-002", type: "RecordingManifest.CapturedProcess", invariant: 16,
            path: "executableName")
    }

    func test_p52_format_isBoundedIndependentlyOfFinalization() throws {
        for value in ["\"flac\"", "\"\"", "\"pcm_caf\""] {
            assertInvariant(try decodeManifest(ManifestJSON.text(
                tracks: "[\(ManifestJSON.track(format: value))]", isFinalized: "false")),
                contract: "C-002", type: "RecordingManifest.Track", invariant: 5, path: "format")
        }
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(format: "\"pcm-caf\""))]", isFinalized: "false")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(format: "\"aac-m4a\""))]", isFinalized: "true")))
    }

    func test_p53_directoryName_equalsRecordingIdString() throws {
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            recordingId: "\"3f2504e0-4f89-41d3-9a0c-0305e82c3301\"")))
        for value in ["\"\"", "\"a/b\"", "\"3f2504e0-4f89-41d3-9a0c-0305e82c3301\"",
                      "\"{3F2504E0-4F89-41D3-9A0C-0305E82C3301}\""] {
            assertInvariant(try decodeManifest(ManifestJSON.text(directoryName: value)),
                            contract: "C-002", type: "RecordingManifest", invariant: 7,
                            path: "directoryName")
        }
    }

    func test_p54_markerPairing_isNotRequired() throws {
        let markers = "[\(ManifestJSON.marker(kind: "\"resume\"", atMs: "10")), " +
            "\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "20"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            markers: markers, discontinuities: "[\(ManifestJSON.gap(atMs: "20"))]")))
    }

    private func manifest(started: Date, ended: Date, markerAtMs: Int) throws -> RecordingManifest {
        let recordingId = try makeUUID(ManifestJSON.identifier)
        return try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: started, endedAt: ended,
            tracks: [try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                 sampleRate: 48_000, channelCount: 1,
                                                 format: "pcm-caf")],
            markers: [try RecordingManifest.Marker(kind: .pause, atMs: markerAtMs, detail: nil)],
            capturedProcesses: [], captureGroupKey: nil, inputDevices: [],
            discontinuities: [], isFinalized: false
        )
    }
}
