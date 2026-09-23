//  TestFixtures — минимальные валидные доменные значения для тестов, владелец: DEV-2.

import Foundation
import DomainCore

enum TestFixtures {

    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func recordingManifest(
        recordingId: UUID = UUID(),
        meetingId: UUID? = nil,
        startedAt: Date = epoch,
        endedAt: Date? = nil,
        isFinalized: Bool = false
    ) throws -> RecordingManifest {
        try RecordingManifest(
            recordingId: recordingId,
            meetingId: meetingId,
            directoryName: recordingId.uuidString,
            startedAt: startedAt,
            endedAt: endedAt,
            tracks: [
                try RecordingManifest.Track(
                    channel: .mic, fileName: "audio-mic.caf",
                    sampleRate: 16_000, channelCount: 1,
                    format: isFinalized ? "aac-m4a" : "pcm-caf"
                )
            ],
            markers: [],
            capturedProcesses: [],
            captureGroupKey: nil,
            inputDevices: [],
            discontinuities: [],
            isFinalized: isFinalized
        )
    }

    static func meetingEvent(
        id: UUID = UUID(),
        sourceConnectorId: String = "eventkit",
        externalId: String = "ext-1",
        title: String = "Standup",
        start: Date = epoch,
        end: Date = epoch.addingTimeInterval(1_800),
        dedupKey: DedupKey? = nil,
        organizer: MeetingEvent.Person? = nil,
        attendees: [MeetingEvent.Attendee] = []
    ) throws -> MeetingEvent {
        try MeetingEvent(
            id: id,
            sourceConnectorId: sourceConnectorId,
            externalId: externalId,
            icalUid: nil,
            title: title,
            start: start,
            end: end,
            timeZone: "UTC",
            isAllDay: false,
            isCancelled: false,
            organizer: organizer,
            attendees: attendees,
            location: nil,
            bodyText: nil,
            conference: nil,
            lastModified: start
        )
    }

    static func segment(
        startMs: Int, endMs: Int, text: String,
        channel: RecordingManifest.Channel = .mic, speakerCluster: Int? = nil
    ) throws -> Transcript.Segment {
        try Transcript.Segment(
            startMs: startMs, endMs: endMs, channel: channel, speakerCluster: speakerCluster,
            text: text, textOriginal: nil, textConfidence: nil, words: []
        )
    }

    static func transcript(
        recordingId: UUID, segments: [Transcript.Segment], speakers: [Transcript.Speaker] = []
    ) throws -> Transcript {
        try Transcript(
            recordingId: recordingId, language: "en", engine: "engine", modelVersion: "1.0",
            createdAt: epoch, segments: segments, speakers: speakers
        )
    }

    static func threeDistinctSegments(prefix: String) throws -> [Transcript.Segment] {
        try [
            segment(startMs: 0, endMs: 1_000, text: "\(prefix) alpha"),
            segment(startMs: 1_000, endMs: 2_000, text: "\(prefix) bravo"),
            segment(startMs: 2_000, endMs: 3_000, text: "\(prefix) charlie")
        ]
    }
}
