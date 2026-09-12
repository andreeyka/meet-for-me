//  Место проверки и тип ошибки: пп. 97, 98, 100, 102, 104.
//
//  Файл импортирует `DomainCore` без `@testable` и собирает значения всех трёх DTO
//  только через `try`: сборка этого файла и есть доказательство п. 97.

import XCTest
import DomainCore

final class ErrorModelTests: XCTestCase {

    func test_p97_publicInitializersAreThrowing() throws {
        let event = try MeetingEvent(
            id: try makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: date(milliseconds: 0), end: date(milliseconds: 1_000), timeZone: "UTC",
            isAllDay: false, isCancelled: false, organizer: nil, attendees: [],
            location: nil, bodyText: nil, conference: nil, lastModified: date(milliseconds: 0)
        )
        let recordingId = try makeUUID(ManifestJSON.identifier)
        let manifest = try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: date(milliseconds: 0), endedAt: nil,
            tracks: [try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                 sampleRate: 48_000, channelCount: 1,
                                                 format: "pcm-caf")],
            markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [], discontinuities: [], isFinalized: false
        )
        let transcript = try Transcript(
            recordingId: recordingId, language: "ru", engine: "eng", modelVersion: "v1",
            createdAt: date(milliseconds: 0), segments: [], speakers: []
        )
        XCTAssertEqual(event.title, "T")
        XCTAssertEqual(manifest.tracks.count, 1)
        XCTAssertEqual(transcript.segments, [])
    }

    func test_p98_validateIsPublicAndInvalidValueNeverExists() throws {
        XCTAssertNoThrow(try MeetingEventFixtureProbe.event().validate())
        assertInvariant(try MeetingEvent(
            id: try makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: date(milliseconds: 1_000), end: date(milliseconds: 999), timeZone: "UTC",
            isAllDay: false, isCancelled: false, organizer: nil, attendees: [],
            location: nil, bodyText: nil, conference: nil, lastModified: date(milliseconds: 0)),
            contract: "C-001", type: "MeetingEvent", invariant: 1, path: "end")
    }

    /// Оба пути создания дают ошибку, совпадающую по четырём структурным полям.
    func test_p100_bothCreationPaths_agree() throws {
        let fromJSON = errorFields(try decodeEvent(EventJSON.text(
            start: "\"2026-09-11T10:00:00.000Z\"", end: "\"2026-09-11T09:30:00.000Z\"")))
        let fromCode = errorFields(try MeetingEvent(
            id: try makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: date(milliseconds: 1_000), end: date(milliseconds: 0), timeZone: "UTC",
            isAllDay: false, isCancelled: false, organizer: nil, attendees: [],
            location: nil, bodyText: nil, conference: nil, lastModified: date(milliseconds: 0)))
        XCTAssertEqual(fromJSON, fromCode)
        XCTAssertEqual(fromCode?.path, "end")

        let trackJSON = errorFields(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: "0"))]", isFinalized: "false")))
        let trackCode = errorFields(try RecordingManifest.Track(
            channel: .mic, fileName: "m.caf", sampleRate: 0, channelCount: 1, format: "pcm-caf"))
        XCTAssertEqual(trackJSON, trackCode)
        XCTAssertEqual(trackCode?.type, "RecordingManifest.Track")

        let wordJSON = errorFields(try decodeTranscript(TranscriptJSON.text(segments:
            "[\(TranscriptJSON.segment(words: "[\(TranscriptJSON.word(confidence: "1.5"))]"))]")))
        let wordCode = errorFields(try Transcript.Word(startMs: 0, endMs: 500, text: "да",
                                                       confidence: 1.5, original: nil))
        XCTAssertEqual(wordJSON, wordCode)
        XCTAssertEqual(wordCode?.type, "Transcript.Word")
    }

    /// Три границы обещания — по числу правил §0.2 п. 9. Все три дают из JSON и из кода
    /// ошибки РАЗНЫХ типов, и это намеренно.
    func test_p100_threeBoundariesOfThePromise() throws {
        assertCorrupted(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(embedding: "[1e400]", embeddingModelVersion: "\"v1\""))]")),
            key: "embedding")
        assertInvariant(try Transcript.Speaker(cluster: 0, embedding: [.infinity],
                                               embeddingModelVersion: "v1", totalMs: 0),
                        contract: "C-003", type: "Transcript.Speaker", invariant: 0,
                        path: "embedding[0]")

        assertCorrupted(try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(atMs: "9007199254740992"))]")), key: "atMs")
        assertInvariant(try RecordingManifest.Marker(kind: .sleep, atMs: 1 << 53, detail: nil),
                        contract: "C-002", type: "RecordingManifest.Marker", invariant: 0,
                        path: "atMs")

        assertCorrupted(try decodeEvent(EventJSON.text(
            lastModified: "\"10000-01-01T00:00:00.000Z\"")), key: "lastModified")
        assertInvariant(try MeetingEvent(
            id: try makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: date(milliseconds: 0), end: date(milliseconds: 1_000), timeZone: "UTC",
            isAllDay: false, isCancelled: false, organizer: nil, attendees: [],
            location: nil, bodyText: nil, conference: nil,
            lastModified: Date(timeIntervalSince1970: 253_402_300_800)),
            contract: "C-001", type: "MeetingEvent", invariant: 0, path: "lastModified")
    }

    func test_p102_descriptionCarriesTypeInItsHead() throws {
        let failure = try XCTUnwrap(validationError(try decodeEvent(EventJSON.text(
            attendees: "[\(EventJSON.attendee(email: "\"ivan\""))]"))))
        XCTAssertTrue(failure.description.hasPrefix("C-001.MeetingEvent.Person инв. 3, email: "))

        let word = try XCTUnwrap(validationError(try Transcript.Word(
            startMs: 100, endMs: 50, text: "да", confidence: nil, original: nil)))
        XCTAssertTrue(word.description.hasPrefix("C-003.Transcript.Word инв. 4, endMs: "))

        let marker = try XCTUnwrap(validationError(try RecordingManifest.Marker(
            kind: .sleep, atMs: -1, detail: nil)))
        XCTAssertTrue(marker.description.hasPrefix("C-002.RecordingManifest.Marker инв. 8, atMs: "))

        let span = try XCTUnwrap(validationError(try RecordingManifest.InputDeviceSpan(
            atMs: -1, present: true, name: nil, uid: nil)))
        let expected = "C-002.RecordingManifest.InputDeviceSpan инв. 9, atMs: "
        XCTAssertTrue(span.description.hasPrefix(expected))
        XCTAssertFalse(span.description.hasPrefix("C-002.RecordingManifest.Marker инв. 8, "))
    }

    func test_p104_errorKinds_areDistinguishable() throws {
        XCTAssertThrowsError(try decodeManifest("{ битый")) { error in
            XCTAssertTrue(error is DecodingError, "\(error)")
        }
        assertKeyNotFound(try decodeManifest(withoutArrayKey(ManifestJSON.text(), "tracks")),
                          key: "tracks")
        assertTypeMismatch(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: "\"48000\""))]", isFinalized: "false")))
        assertInvariant(try decodeManifest(ManifestJSON.text(tracks: "[]")),
                        contract: "C-002", type: "RecordingManifest", invariant: 2, path: "tracks")
    }

    /// Три исхода одного поля рядом: строка — несовпадение типа, `4.8e4` — принято,
    /// `1.5` — битый JSON, а не молчаливое усечение.
    func test_p104_int_threeOutcomesOfOneField() throws {
        assertTypeMismatch(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: "\"48000\""))]", isFinalized: "false")))
        let decoded = try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: "4.8e4"))]", isFinalized: "false"))
        XCTAssertEqual(decoded.tracks.first?.sampleRate, 48_000)
        assertCorrupted(try decodeManifest(ManifestJSON.text(
            tracks: "[\(ManifestJSON.track(sampleRate: "1.5"))]", isFinalized: "false")),
            key: "sampleRate")
    }
}

/// Значение, собранное публичным инициализатором без `@testable`.
enum MeetingEventFixtureProbe {
    static func event() throws -> MeetingEvent {
        try MeetingEvent(
            id: try makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: date(milliseconds: 0), end: date(milliseconds: 1_000), timeZone: "UTC",
            isAllDay: false, isCancelled: false, organizer: nil, attendees: [],
            location: nil, bodyText: nil, conference: nil, lastModified: date(milliseconds: 0)
        )
    }
}
