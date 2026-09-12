//  Значения, нарушающие ровно один названный инвариант, — для пары векторов п. 132.
//
//  Рядом с каждым вектором «нарушено и то, и другое» обязан стоять вектор «нарушен только
//  инвариант», сохраняющий прежний ответ: порознь каждая половина зелена на реализации
//  с прежним порядком ступеней.

import Foundation
import DomainCore

enum EventProbe {

    private static let validStart = Date(timeIntervalSince1970: 1_789_113_600)
    private static let validEnd = Date(timeIntervalSince1970: 1_789_117_200)

    static func event(timeZone: String = "UTC", duplicateAddresses: Bool = false,
                      lastModified: Date = validStart) throws -> MeetingEvent {
        let attendees: [MeetingEvent.Attendee]
        if duplicateAddresses {
            let person = try MeetingEvent.Person(name: "Иван", email: "ivan@example.com")
            attendees = [
                try MeetingEvent.Attendee(person: person, responseStatus: .accepted,
                                          isOptional: false),
                try MeetingEvent.Attendee(person: person, responseStatus: .declined,
                                          isOptional: false)
            ]
        } else {
            attendees = []
        }
        return try MeetingEvent(
            id: try makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: validStart, end: validEnd, timeZone: timeZone, isAllDay: false,
            isCancelled: false, organizer: nil, attendees: attendees, location: nil,
            bodyText: nil, conference: nil, lastModified: lastModified
        )
    }

    /// Событие на весь день, у которого `end` не является первым мгновением суток.
    static func allDayWithBrokenEnd(lastModified: Date = validStart) throws -> MeetingEvent {
        try MeetingEvent(
            id: try makeUUID("11111111-1111-4111-8111-111111111111"),
            sourceConnectorId: "eventkit", externalId: "evt-1", icalUid: nil, title: "T",
            start: Date(timeIntervalSince1970: 1_789_074_000),
            end: Date(timeIntervalSince1970: 1_789_160_401),
            timeZone: "Europe/Moscow", isAllDay: true, isCancelled: false,
            organizer: nil, attendees: [], location: nil, bodyText: nil,
            conference: nil, lastModified: lastModified
        )
    }
}

enum ManifestProbe {

    enum RootViolation {
        case schemaVersion
        case twoMicTracks
        case duplicateFileName
        case directoryName
        case unsortedMarkers
        case unsortedSpans
        case orphanDeviceChange
        case markerBeyondDuration
        case endedBeforeStarted
        case finalizedWithoutEnd
        case unsortedGaps
        case orphanDiscontinuity
        case emptyCaptureGroupKey

        var invariant: Int {
            switch self {
            case .schemaVersion: return 1
            case .twoMicTracks: return 2
            case .duplicateFileName: return 4
            case .directoryName: return 7
            case .unsortedMarkers: return 8
            case .unsortedSpans: return 9
            case .orphanDeviceChange: return 10
            case .markerBeyondDuration: return 11
            case .endedBeforeStarted: return 12
            case .finalizedWithoutEnd: return 13
            case .unsortedGaps: return 14
            case .orphanDiscontinuity: return 15
            case .emptyCaptureGroupKey: return 16
            }
        }
    }

    static let rootViolations: [RootViolation] = [
        .schemaVersion, .twoMicTracks, .duplicateFileName, .directoryName, .unsortedMarkers,
        .unsortedSpans, .orphanDeviceChange, .markerBeyondDuration, .endedBeforeStarted,
        .finalizedWithoutEnd, .unsortedGaps, .orphanDiscontinuity, .emptyCaptureGroupKey
    ]

    private static let started = Date(timeIntervalSince1970: 1_789_113_600)
    private static let ended = Date(timeIntervalSince1970: 1_789_117_200)

    // swiftlint:disable:next cyclomatic_complexity
    static func manifest(violation: RootViolation,
                         startedAt: Date? = nil) throws -> RecordingManifest {
        var shape = Shape()
        switch violation {
        case .schemaVersion: shape.schemaVersion = 2
        case .twoMicTracks: shape.tracks = [try track(.mic, "a.caf"), try track(.mic, "b.caf")]
        case .duplicateFileName: shape.tracks = [try track(.mic, "a.caf"),
                                                 try track(.system, "a.caf")]
        case .directoryName: shape.directoryName = "не-каталог-записи"
        case .unsortedMarkers: shape.markers = [try marker(.pause, 50), try marker(.pause, 10)]
        case .unsortedSpans: shape.inputDevices = [try span(0), try span(5_000), try span(3_000)]
            shape.markers = [try marker(.deviceChanged, 3_000), try marker(.deviceChanged, 5_000)]
        case .orphanDeviceChange: shape.markers = [try marker(.deviceChanged, 5_000)]
        case .markerBeyondDuration: shape.markers = [try marker(.pause, 3_600_001)]
        case .endedBeforeStarted: shape.endedAt = Date(timeIntervalSince1970: 1_789_113_599)
        case .finalizedWithoutEnd: shape.endedAt = nil
            shape.isFinalized = true
            shape.tracks = [try track(.mic, "a.m4a", format: "aac-m4a")]
        case .unsortedGaps: shape.markers = [try marker(.discontinuity, 10),
                                             try marker(.discontinuity, 50)]
            shape.discontinuities = [try gap(50), try gap(10)]
        case .orphanDiscontinuity: shape.discontinuities = [try gap(10)]
        case .emptyCaptureGroupKey: shape.captureGroupKey = ""
        }
        let recordingId = try makeUUID(ManifestJSON.identifier)
        let tracks = try shape.tracks ?? [track(.mic, "a.caf")]
        return try RecordingManifest(
            schemaVersion: shape.schemaVersion, recordingId: recordingId, meetingId: nil,
            directoryName: shape.directoryName ?? recordingId.uuidString,
            startedAt: startedAt ?? started, endedAt: shape.endedAt,
            tracks: tracks,
            markers: shape.markers, capturedProcesses: [],
            captureGroupKey: shape.captureGroupKey, inputDevices: shape.inputDevices,
            discontinuities: shape.discontinuities, isFinalized: shape.isFinalized
        )
    }

    private struct Shape {
        var schemaVersion = RecordingManifest.currentSchemaVersion
        var directoryName: String?
        var endedAt: Date? = ended
        var tracks: [RecordingManifest.Track]?
        var markers: [RecordingManifest.Marker] = []
        var captureGroupKey: String?
        var inputDevices: [RecordingManifest.InputDeviceSpan] = []
        var discontinuities: [RecordingManifest.Discontinuity] = []
        var isFinalized = false
    }

    private static func track(_ channel: RecordingManifest.Channel, _ fileName: String,
                              format: String = "pcm-caf") throws -> RecordingManifest.Track {
        try RecordingManifest.Track(channel: channel, fileName: fileName, sampleRate: 48_000,
                                    channelCount: 1, format: format)
    }

    private static func marker(_ kind: RecordingManifest.MarkerKind,
                               _ atMs: Int) throws -> RecordingManifest.Marker {
        try RecordingManifest.Marker(kind: kind, atMs: atMs, detail: nil)
    }

    private static func span(_ atMs: Int) throws -> RecordingManifest.InputDeviceSpan {
        try RecordingManifest.InputDeviceSpan(atMs: atMs, present: true, name: nil, uid: nil)
    }

    private static func gap(_ atMs: Int) throws -> RecordingManifest.Discontinuity {
        try RecordingManifest.Discontinuity(atMs: atMs, gapMs: 0, scaleErrorMs: 150,
                                            reason: .rebuild)
    }
}

enum TranscriptProbe {

    enum Violation {
        case unsortedSegments
        case missingCluster
        case duplicateCluster
        case differingEmbeddingLengths
        case badLanguage
        case overlappingSameChannel
    }

    static func transcript(violation: Violation,
                           createdAt: Date = Date(timeIntervalSince1970: 1_789_113_600))
    throws -> Transcript {
        var language = "ru"
        var segments: [Transcript.Segment] = []
        var speakers: [Transcript.Speaker] = []
        switch violation {
        case .unsortedSegments:
            segments = [try segment(0, 500), try segment(1_000, 1_500), try segment(600, 900)]
        case .missingCluster:
            segments = [try segment(0, 500, channel: .system, cluster: 7)]
        case .duplicateCluster:
            speakers = [try speaker(0), try speaker(0)]
        case .differingEmbeddingLengths:
            speakers = [try speaker(0, embedding: [0.1, 0.2]), try speaker(1, embedding: [0.1])]
        case .badLanguage:
            language = "РУССКИЙ"
        case .overlappingSameChannel:
            segments = [try segment(0, 1_000), try segment(500, 1_500)]
        }
        return try Transcript(
            recordingId: try makeUUID(ManifestJSON.identifier), language: language,
            engine: "gigaam-sherpa-onnx", modelVersion: "v3.0.1", createdAt: createdAt,
            segments: segments, speakers: speakers
        )
    }

    private static func segment(_ startMs: Int, _ endMs: Int,
                                channel: RecordingManifest.Channel = .mic,
                                cluster: Int? = nil) throws -> Transcript.Segment {
        try Transcript.Segment(startMs: startMs, endMs: endMs, channel: channel,
                               speakerCluster: cluster, text: "речь", textOriginal: nil,
                               textConfidence: nil, words: [])
    }

    private static func speaker(_ cluster: Int,
                                embedding: [Float]? = nil) throws -> Transcript.Speaker {
        try Transcript.Speaker(cluster: cluster, embedding: embedding,
                               embeddingModelVersion: embedding == nil ? nil : "emb-v1",
                               totalMs: 0)
    }
}
