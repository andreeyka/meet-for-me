//  Версия схемы и неизвестные значения перечислений: пп. 113, 114.

import XCTest
import DomainCore

final class SchemaAndEnumTests: XCTestCase {

    func test_p113_currentSchemaVersions_arePublicAndDifferent() {
        XCTAssertEqual(RecordingManifest.currentSchemaVersion, 3)
        XCTAssertEqual(Transcript.currentSchemaVersion, 2)
    }

    func test_p113_manifestSchemaVersion() throws {
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(schemaVersion: "3")))
        for value in ["2", "4"] {
            assertInvariant(try decodeManifest(ManifestJSON.text(schemaVersion: value)),
                            contract: "C-002", type: "RecordingManifest", invariant: 1,
                            path: "schemaVersion")
        }
        let stripped = ManifestJSON.text()
            .replacingOccurrences(of: "\"schemaVersion\": 3, ", with: "")
        assertKeyNotFound(try decodeManifest(stripped), key: "schemaVersion")
        assertTypeMismatch(try decodeManifest(ManifestJSON.text(schemaVersion: "\"3\"")))
    }

    /// Вектор «файл предыдущей схемы»: единственная проверка первого в проекте повышения.
    func test_p113_previousSchemaFile_isRejected() throws {
        assertInvariant(try decodeManifest(ManifestJSON.text(schemaVersion: "2")),
                        contract: "C-002", type: "RecordingManifest", invariant: 1,
                        path: "schemaVersion")
    }

    func test_p113_transcriptSchemaVersion() throws {
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(schemaVersion: "2")))
        for value in ["1", "3"] {
            assertInvariant(try decodeTranscript(TranscriptJSON.text(schemaVersion: value)),
                            contract: "C-003", type: "Transcript", invariant: 1,
                            path: "schemaVersion")
        }
    }

    func test_p113_int_literalFormIsFree() throws {
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(schemaVersion: "3.0")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(schemaVersion: "3e0")))
        assertInvariant(try decodeManifest(ManifestJSON.text(schemaVersion: "2.0")),
                        contract: "C-002", type: "RecordingManifest", invariant: 1,
                        path: "schemaVersion")
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(schemaVersion: "2.0")))
        assertCorrupted(try decodeManifest(ManifestJSON.text(schemaVersion: "2.5")),
                        key: "schemaVersion")
    }

    /// Утверждение «`schemaVersion` никогда не даёт `invariant = 0`» отменено как неверное.
    func test_p113_int_unrepresentableSchemaVersionFromCode() throws {
        let recordingId = try makeUUID(ManifestJSON.identifier)
        assertInvariant(try RecordingManifest(
            schemaVersion: 1 << 53, recordingId: recordingId, meetingId: nil,
            directoryName: recordingId.uuidString, startedAt: date(milliseconds: 0), endedAt: nil,
            tracks: [try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                 sampleRate: 48_000, channelCount: 1,
                                                 format: "pcm-caf")],
            markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [], discontinuities: [], isFinalized: false),
            contract: "C-002", type: "RecordingManifest", invariant: 0, path: "schemaVersion")
        assertCorrupted(try decodeManifest(ManifestJSON.text(schemaVersion: "9007199254740992")),
                        key: "schemaVersion")
    }

    /// Публичный инициализатор имеет значение по умолчанию, и собранное так значение валидно.
    func test_p113_defaultSchemaVersionIsValid() throws {
        let recordingId = try makeUUID(ManifestJSON.identifier)
        let manifest = try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: date(milliseconds: 0), endedAt: nil,
            tracks: [try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                 sampleRate: 48_000, channelCount: 1,
                                                 format: "pcm-caf")],
            markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [], discontinuities: [], isFinalized: false)
        XCTAssertEqual(manifest.schemaVersion, RecordingManifest.currentSchemaVersion)
        let transcript = try Transcript(recordingId: recordingId, language: "ru", engine: "eng",
                                        modelVersion: "v1", createdAt: date(milliseconds: 0),
                                        segments: [], speakers: [])
        XCTAssertEqual(transcript.schemaVersion, Transcript.currentSchemaVersion)
    }

    // MARK: - п. 114

    func test_p114_unknownEnumValue_losesItsRawStringOnReEncode() throws {
        let markers = "[\(ManifestJSON.marker(kind: "\"pause\"", atMs: "5")), " +
            "\(ManifestJSON.marker(kind: "\"thermalThrottle\"", atMs: "10")), " +
            "\(ManifestJSON.marker(kind: "\"discontinuity\"", atMs: "20"))]"
        let gaps = "[\(ManifestJSON.gap(atMs: "20", reason: "\"gpuReset\""))]"
        let decoded = try decodeManifest(ManifestJSON.text(markers: markers, discontinuities: gaps))
        XCTAssertEqual(decoded.markers[0].kind, .pause)
        XCTAssertEqual(decoded.markers[1].kind, .unknown)
        XCTAssertEqual(decoded.markers[2].kind, .discontinuity)
        XCTAssertEqual(decoded.discontinuities[0].reason, .unknown)
        let text = try encodedText(decoded)
        XCTAssertTrue(text.contains("\"unknown\""))
        XCTAssertFalse(text.contains("thermalThrottle"))
        XCTAssertFalse(text.contains("gpuReset"))
    }

    func test_p114_responseStatusUnknown_behavesTheSame() throws {
        let attendees = "[\(EventJSON.attendee(email: "null", status: "\"accepted\"")), " +
            "\(EventJSON.attendee(email: "null", status: "\"delegated\""))]"
        let decoded = try decodeEvent(EventJSON.text(attendees: attendees))
        XCTAssertEqual(decoded.attendees[0].responseStatus, .accepted)
        XCTAssertEqual(decoded.attendees[1].responseStatus, .unknown)
        let text = try encodedText(decoded)
        XCTAssertFalse(text.contains("delegated"))
    }

    /// Признак перечисления, которому случай `unknown` объявлен контрактом: он есть
    /// у трёх перечислений и его нет у `Channel`.
    func test_p114_enumsWithoutUnknownRejectUnknownValue() {
        XCTAssertNotNil(RecordingManifest.MarkerKind(rawValue: "unknown"))
        XCTAssertNotNil(RecordingManifest.DiscontinuityReason(rawValue: "unknown"))
        XCTAssertNotNil(MeetingEvent.Attendee.ResponseStatus(rawValue: "unknown"))
        XCTAssertNil(RecordingManifest.Channel(rawValue: "unknown"))
    }
}
