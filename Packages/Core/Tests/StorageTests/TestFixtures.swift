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

    /// К109 (MEE-422): непустые, различные `text`/`textOriginal`/`words`, с хотя бы одним
    /// словом, чей `original` отличен от текущего `text` — то, что `markSegmentsUserEdited`
    /// обязан оставить побайтово нетронутым.
    static func segmentWithEditHistory(
        startMs: Int, endMs: Int, text: String, textOriginal: String, wordOriginal: String
    ) throws -> Transcript.Segment {
        let words = [
            try Transcript.Word(
                startMs: startMs, endMs: startMs + 100, text: text, confidence: 0.9, original: wordOriginal
            )
        ]
        return try Transcript.Segment(
            startMs: startMs, endMs: endMs, channel: .mic, speakerCluster: nil,
            text: text, textOriginal: textOriginal, textConfidence: 0.9, words: words
        )
    }

    /// Поля `Job` сверх пяти обязательных параметров `job(id:type:payload:status:options:)`
    /// (лимит `function_parameter_count`) — значения по умолчанию соответствуют
    /// только что созданной, ничем не занятой задаче.
    struct JobOptions {
        var priority = 0
        var attempts = 0
        var maxAttempts = 3
        var runAfter = TestFixtures.epoch
        var conditions = JobConditions(
            requiresACPower: false, forbidWhileRecording: false,
            maxThermalPressure: .fair, requiresProfileReady: nil
        )
        var dedupKey: String?
        var leaseExpiresAt: Date?
        var attemptStartedAt: Date?
        var lastError: String?
        var createdAt = TestFixtures.epoch
        var updatedAt = TestFixtures.epoch
    }

    static func job(
        id: UUID = UUID(),
        type: JobType = .transcode,
        payload: JobPayload = .transcode(recordingId: UUID()),
        status: JobStatus = .pending,
        options: JobOptions = JobOptions()
    ) -> Job {
        Job(
            id: id, type: type, payload: payload, status: status,
            priority: options.priority, attempts: options.attempts, maxAttempts: options.maxAttempts,
            runAfter: options.runAfter, conditions: options.conditions, dedupKey: options.dedupKey,
            leaseExpiresAt: options.leaseExpiresAt, attemptStartedAt: options.attemptStartedAt,
            lastError: options.lastError, createdAt: options.createdAt, updatedAt: options.updatedAt
        )
    }
}
