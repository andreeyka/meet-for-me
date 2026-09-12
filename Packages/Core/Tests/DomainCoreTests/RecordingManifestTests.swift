//  Раздел Е перечня: инварианты C-002, пп. 38—45.

import XCTest
import DomainCore

final class RecordingManifestTests: XCTestCase {

    private let micTrack = ManifestJSON.track()
    private let systemTrack = ManifestJSON.track(channel: "\"system\"", fileName: "\"s.m4a\"")

    func test_p38_emptyTracks_areRejected() throws {
        assertInvariant(try decodeManifest(ManifestJSON.text(tracks: "[]")),
                        contract: "C-002", type: "RecordingManifest", invariant: 2, path: "tracks")
    }

    func test_p39_oneTrackPerChannel() throws {
        let twoMic = "[\(micTrack), \(ManifestJSON.track(fileName: "\"m2.m4a\""))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(tracks: twoMic)),
                        contract: "C-002", type: "RecordingManifest", invariant: 2, path: "tracks")
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(tracks: "[\(micTrack), \(systemTrack)]")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(tracks: "[\(micTrack)]")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(tracks: "[\(systemTrack)]")))
    }

    /// Вектор Q1: нарушитель — поздний элемент пары, индекс 2.
    func test_p40_markersMustNotDecrease() throws {
        let markers = "[\(ManifestJSON.marker(atMs: "0")), \(ManifestJSON.marker(atMs: "50")), " +
            "\(ManifestJSON.marker(atMs: "40")), \(ManifestJSON.marker(atMs: "30"))]"
        assertInvariant(try decodeManifest(ManifestJSON.text(markers: markers)),
                        contract: "C-002", type: "RecordingManifest", invariant: 8,
                        path: "markers[2].atMs")
    }

    func test_p40_equalMarkerTimes_areAccepted() throws {
        let markers = "[\(ManifestJSON.marker(kind: "\"sleep\"", atMs: "1800000")), " +
            "\(ManifestJSON.marker(kind: "\"wake\"", atMs: "1800000"))]"
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(markers: markers)))
    }

    /// Пара с п. 40 в одном тесте: две половины одного инварианта сообщаются разными типами.
    func test_p41_negativeMarkerTime_isRejectedByMarker() throws {
        assertInvariant(try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(atMs: "-1"))]")),
            contract: "C-002", type: "RecordingManifest.Marker", invariant: 8, path: "atMs")
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(atMs: "0"))]")))
    }

    func test_p42_endedAtBeforeStartedAt_isRejected() throws {
        assertInvariant(try decodeManifest(ManifestJSON.text(
            startedAt: "\"2026-09-11T09:00:00.000Z\"", endedAt: "\"2026-09-11T08:00:00.000Z\"")),
            contract: "C-002", type: "RecordingManifest", invariant: 12, path: "endedAt")
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            startedAt: "\"2026-09-11T08:00:00.000Z\"", endedAt: "\"2026-09-11T08:00:00.000Z\"")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(endedAt: "null",
                                                              isFinalized: "false")))
    }

    func test_p43_finalizedRequiresEndedAtAndAAC() throws {
        assertInvariant(try decodeManifest(ManifestJSON.text(endedAt: "null")),
                        contract: "C-002", type: "RecordingManifest", invariant: 13, path: "endedAt")
        let rawSystem = ManifestJSON.track(channel: "\"system\"", fileName: "\"s.caf\"",
                                           format: "\"pcm-caf\"")
        let mixed = "[\(micTrack), \(rawSystem)]"
        assertInvariant(try decodeManifest(ManifestJSON.text(tracks: mixed)),
                        contract: "C-002", type: "RecordingManifest", invariant: 13,
                        path: "tracks[1].format")
    }

    func test_p44_notFinalized_isOneSided() throws {
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(isFinalized: "false")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(format: "\"pcm-caf\""))]", isFinalized: "false")))
    }

    func test_p45_sampleRateAndChannelCount_mustBePositive() throws {
        for (value, path) in [("0", "sampleRate"), ("-48000", "sampleRate")] {
            assertInvariant(try decodeManifest(ManifestJSON.text(
                tracks: "[\(ManifestJSON.track(sampleRate: value))]", isFinalized: "false")),
                contract: "C-002", type: "RecordingManifest.Track", invariant: 6, path: path)
        }
        assertInvariant(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(channelCount: "0"))]", isFinalized: "false")),
            contract: "C-002", type: "RecordingManifest.Track", invariant: 6, path: "channelCount")
        for value in ["8000", "1000000000", "9007199254740991"] {
            XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
                tracks: "[\(ManifestJSON.track(sampleRate: value))]", isFinalized: "false")), value)
        }
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(channelCount: "8"))]", isFinalized: "false")))
    }

    /// Верхней границы нет у инварианта 6; она есть у §0.2 п. 9 и равна 2^53 − 1.
    func test_p45_beyondInteroperableRange_isParseFailure() throws {
        for value in ["9007199254740992", "9223372036854775808"] {
            assertCorrupted(try decodeManifest(ManifestJSON.text(
                tracks: "[\(ManifestJSON.track(sampleRate: value))]", isFinalized: "false")),
                key: "sampleRate")
        }
    }

    /// Пара на порядок ступеней подаётся только из кода: из JSON тот же литерал отсекает
    /// `decodeBounded` при разборе и проверяет не то, ради чего вектор написан.
    func test_p45_unrepresentableFromCode_isRepresentabilityNotInvariant() throws {
        assertInvariant(try RecordingManifest.Track(channel: .mic, fileName: "mic.caf",
                                                    sampleRate: -9_007_199_254_740_992,
                                                    channelCount: 1, format: "pcm-caf"),
                        contract: "C-002", type: "RecordingManifest.Track", invariant: 0,
                        path: "sampleRate")
        assertInvariant(try RecordingManifest.Track(channel: .mic, fileName: "mic.caf",
                                                    sampleRate: 48_000, channelCount: 1 << 53,
                                                    format: "pcm-caf"),
                        contract: "C-002", type: "RecordingManifest.Track", invariant: 0,
                        path: "channelCount")
    }
}
