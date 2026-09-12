//  Раздел В перечня: пп. 16, 17, 21 — неизвестные ключи и состав ключей корня.

import XCTest
import DomainCore
import DomainTestKit

final class UnknownKeysTests: XCTestCase {

    private let extra = ", \"whateverUnknown\": 1"

    /// Четырнадцать уровней вложенности, отдельным случаем на каждый.
    func test_p16_unknownKey_isIgnoredAtEveryLevel() throws {
        let attendee = EventJSON.attendee(email: "\"ivan@example.com\"")
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(tail: extra)))
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(
            attendees: "[\(attendee.dropLast())\(extra)}]")))
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(
            organizer: "\(EventJSON.person(email: "null").dropLast())\(extra)}",
            attendees: "[\(EventJSON.attendee(email: "null"))]")))
        XCTAssertNoThrow(try decodeEvent(EventJSON.text(
            conference: EventJSON.conference(tail: extra))))

        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(tail: extra)))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(tail: extra))]", isFinalized: "false")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(tail: extra))]")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            capturedProcesses: "[\(ManifestJSON.process(tail: extra))]")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            inputDevices: "[\(ManifestJSON.span(tail: extra))]")))
        XCTAssertNoThrow(try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(kind: "\"discontinuity\""))]",
            discontinuities: "[\(ManifestJSON.gap(tail: extra))]")))

        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(tail: extra)))
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(tail: extra))]")))
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            segments: "[\(TranscriptJSON.segment(words: "[\(TranscriptJSON.word(tail: extra))]"))]")))
        XCTAssertNoThrow(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(tail: extra))]")))
    }

    func test_p17_unknownKey_isLostOnReEncode() throws {
        let decoded = try decodeEvent(EventJSON.text(tail: extra))
        XCTAssertFalse(try encodedText(decoded).contains("whateverUnknown"))
    }

    func test_p21_manifestRootKeys_areFixed() throws {
        let expected: Set<String> = ["schemaVersion", "recordingId", "meetingId", "directoryName",
                                     "startedAt", "endedAt", "tracks", "markers",
                                     "capturedProcesses", "captureGroupKey", "inputDevices",
                                     "discontinuities", "isFinalized"]
        let manifest = try decodeManifest(ManifestJSON.text(
            meetingId: "\"3F2504E0-4F89-41D3-9A0C-0305E82C3302\"",
            captureGroupKey: "\"bundle:us.zoom.xos\""))
        XCTAssertEqual(try keys(of: manifest), expected)
        XCTAssertEqual(expected.count, 13)
    }

    func test_p21_transcriptRootKeys_areFixed() throws {
        let expected: Set<String> = ["schemaVersion", "recordingId", "language", "engine",
                                     "modelVersion", "createdAt", "segments", "speakers"]
        XCTAssertEqual(try keys(of: try decodeTranscript(TranscriptJSON.text())), expected)
        XCTAssertEqual(expected.count, 8)
    }

    func test_p21_nestedKeySets_areFixed() throws {
        let manifest = try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(kind: "\"discontinuity\""))]",
            inputDevices: "[\(ManifestJSON.span(name: "\"MacBook\"", uid: "\"BuiltIn\""))]",
            discontinuities: "[\(ManifestJSON.gap())]"))
        let root = try object(of: manifest)
        let gaps = try XCTUnwrap(root["discontinuities"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(gaps.first).keys),
                       ["atMs", "gapMs", "scaleErrorMs", "reason"])
        let spans = try XCTUnwrap(root["inputDevices"] as? [[String: Any]])
        XCTAssertEqual(Set(try XCTUnwrap(spans.first).keys), ["atMs", "present", "name", "uid"])
    }

    /// У `MeetingEvent` поля `schemaVersion` нет: он не формат файла, а полезная нагрузка.
    func test_p21_meetingEvent_hasNoSchemaVersion() throws {
        let decoded = try decodeEvent(EventJSON.text(tail: ", \"schemaVersion\": 3"))
        XCTAssertFalse(try encodedText(decoded).contains("schemaVersion"))
        XCTAssertFalse(try keys(of: MeetingEventFixtures.oneOnOneZoom).contains("schemaVersion"))
    }

    private func object<Value: Encodable>(of value: Value) throws -> [String: Any] {
        let data = try DomainJSON.encode(value)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func keys<Value: Encodable>(of value: Value) throws -> Set<String> {
        Set(try object(of: value).keys)
    }
}
