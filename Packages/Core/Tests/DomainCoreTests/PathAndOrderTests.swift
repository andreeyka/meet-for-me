//  Пункты 101, 105, 106: достижимые значения `path`, детерминизм и порядок ступеней.

import XCTest
import DomainCore

final class PathAndOrderTests: XCTestCase {

    /// Правила §0.1 применяются в порядке 1 → 2 → 3; проверяется парой на одном инварианте.
    func test_p101_rulesAreAppliedInOrder() throws {
        XCTAssertEqual(errorFields(try decodeManifest(ManifestJSON.text(
            markers: "[\(ManifestJSON.marker(atMs: "-1"))]"))),
            ErrorFields(contract: "C-002", type: "RecordingManifest.Marker",
                        invariant: 8, path: "atMs"))
        let unsorted = "[\(ManifestJSON.marker(atMs: "0")), \(ManifestJSON.marker(atMs: "50")), " +
            "\(ManifestJSON.marker(atMs: "40"))]"
        XCTAssertEqual(errorFields(try decodeManifest(ManifestJSON.text(markers: unsorted))),
                       ErrorFields(contract: "C-002", type: "RecordingManifest",
                                   invariant: 8, path: "markers[2].atMs"))
    }

    /// Правило 1, инвариант проверяет сам вложенный тип: путь короткий, индекса в нём нет.
    func test_p101_nestedInvariants_giveShortPaths() throws {
        XCTAssertEqual(errorFields(try decodeEvent(EventJSON.text(
            attendees: "[\(EventJSON.attendee(email: "null")), " +
                "\(EventJSON.attendee(email: "\"ivan\""))]")))?.path, "email")
        XCTAssertEqual(errorFields(try decodeTranscript(TranscriptJSON.text(
            speakers: "[\(TranscriptJSON.speaker(cluster: "-1"))]")))?.path, "cluster")
        XCTAssertEqual(errorFields(try RecordingManifest.Track(
            channel: .mic, fileName: "", sampleRate: 48_000,
            channelCount: 1, format: "pcm-caf"))?.path, "fileName")
    }

    /// Правило 1 у инварианта, который проверяет родитель, и правило 3 — о коллекции целиком.
    func test_p101_parentInvariants_giveCompositeOrCollectionPaths() throws {
        let mixed = "[\(ManifestJSON.track()), " +
            "\(ManifestJSON.track(channel: "\"system\"", fileName: "\"s.caf\"", format: "\"pcm-caf\""))]"
        XCTAssertEqual(errorFields(try decodeManifest(ManifestJSON.text(tracks: mixed)))?.path,
                       "tracks[1].format")
        let duplicates = "[\(EventJSON.attendee(email: "\"a@b\"")), " +
            "\(EventJSON.attendee(email: "\"a@b\""))]"
        XCTAssertEqual(errorFields(try decodeEvent(EventJSON.text(attendees: duplicates)))?.path,
                       "attendees")
        XCTAssertEqual(errorFields(try decodeManifest(ManifestJSON.text(tracks: "[]")))?.path,
                       "tracks")
        let twoSame = "[\(TranscriptJSON.speaker(cluster: "0")), \(TranscriptJSON.speaker(cluster: "0"))]"
        XCTAssertEqual(errorFields(try decodeTranscript(TranscriptJSON.text(speakers: twoSame)))?.path,
                       "speakers")
    }

    func test_p105_errorIsDeterministic() throws {
        let data = Data(ManifestJSON.text(tracks: "[]").utf8)
        let first = errorFields(try DomainJSON.decode(RecordingManifest.self, from: data))
        for _ in 0..<10 {
            XCTAssertEqual(errorFields(try DomainJSON.decode(RecordingManifest.self, from: data)),
                           first)
        }
    }

    /// Fail-fast: среди собственных инвариантов порядок по возрастанию номера.
    func test_p105_failFastAmongOwnInvariants() throws {
        XCTAssertEqual(errorFields(try decodeEvent(EventJSON.text(
            start: "\"2026-09-11T10:00:00.000Z\"", end: "\"2026-09-11T09:30:00.000Z\"",
            timeZone: "\"Nowhere/Nothing\""))),
            ErrorFields(contract: "C-001", type: "MeetingEvent", invariant: 1, path: "end"))
    }

    /// Вектор Q22: единственный вход, на котором видны обе половины правила — (в) раньше (б)
    /// и обход внутри (в) в порядке объявления.
    func test_p105_stageCPrecedesStageB_onSpeaker() throws {
        assertInvariant(try Transcript.Speaker(cluster: 0, embedding: [0.1, .infinity, 0.3],
                                               embeddingModelVersion: "v1", totalMs: -1),
                        contract: "C-003", type: "Transcript.Speaker", invariant: 0,
                        path: "embedding[1]")
        assertInvariant(try Transcript.Speaker(cluster: 0, embedding: [.infinity, 0.3],
                                               embeddingModelVersion: "v1", totalMs: 0),
                        contract: "C-003", type: "Transcript.Speaker", invariant: 0,
                        path: "embedding[0]")
    }

    /// Вектор Q20: реализация, поставившая собственные инварианты типа раньше проверки
    /// представимости, краснеет здесь.
    func test_p105_stageCPrecedesStageB_onTrack() throws {
        assertInvariant(try RecordingManifest.Track(channel: .mic, fileName: "mic.caf",
                                                    sampleRate: 0, channelCount: 1 << 53,
                                                    format: "pcm-caf"),
                        contract: "C-002", type: "RecordingManifest.Track", invariant: 0,
                        path: "channelCount")
    }

    func test_p106_stageAPrecedesEverything() throws {
        XCTAssertEqual(errorFields(try decodeEvent(EventJSON.text(
            start: "\"2026-09-11T10:00:00.000Z\"", end: "\"2026-09-11T09:30:00.000Z\"",
            attendees: "[\(EventJSON.attendee(email: "\"ivan\""))]"))),
            ErrorFields(contract: "C-001", type: "MeetingEvent.Person",
                        invariant: 3, path: "email"))
    }

    /// Порядок обхода ступени (а): `attendees` объявлен раньше `conference`.
    func test_p106_nestedTraversalFollowsDeclarationOrder() throws {
        XCTAssertEqual(errorFields(try decodeEvent(EventJSON.text(
            attendees: "[\(EventJSON.attendee(email: "null")), " +
                "\(EventJSON.attendee(email: "\"ivan\""))]",
            conference: EventJSON.conference(joinUrl: "\"http://zoom.us/j/1\""))))?.type,
            "MeetingEvent.Person")
    }

    func test_p106_stageCPrecedesStageB_onRoot() throws {
        assertInvariant(try MeetingEvent(
            id: try makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: date(milliseconds: 1_000), end: date(milliseconds: 0), timeZone: "UTC",
            isAllDay: false, isCancelled: false, organizer: nil, attendees: [],
            location: nil, bodyText: nil, conference: nil,
            lastModified: Date(timeIntervalSince1970: 253_402_300_800)),
            contract: "C-001", type: "MeetingEvent", invariant: 0, path: "lastModified")
    }

    /// Ошибка принадлежит владельцу поля, а не контракту, в котором записано правило.
    func test_p106_errorBelongsToFieldOwner() throws {
        let recordingId = try makeUUID(ManifestJSON.identifier)
        assertInvariant(try RecordingManifest(
            recordingId: recordingId, meetingId: nil, directoryName: recordingId.uuidString,
            startedAt: date(milliseconds: 0),
            endedAt: Date(timeIntervalSince1970: 253_402_300_800),
            tracks: [try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                 sampleRate: 48_000, channelCount: 1,
                                                 format: "pcm-caf")],
            markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [], discontinuities: [], isFinalized: false),
            contract: "C-002", type: "RecordingManifest", invariant: 0, path: "endedAt")
        assertInvariant(try RecordingManifest.Track(channel: .mic, fileName: "m.caf",
                                                    sampleRate: 1 << 53, channelCount: 2,
                                                    format: "pcm-caf"),
                        contract: "C-002", type: "RecordingManifest.Track", invariant: 0,
                        path: "sampleRate")
    }
}
