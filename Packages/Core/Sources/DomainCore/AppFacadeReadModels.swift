//  AppFacade.swift §1 (модели чтения) — C-016 v9 (MEE-25). Разведено в отдельный файл по
//  объёму (`file_length`), не по смыслу: `AppFacade.swift` с этим разделом внутри
//  перерастал предел SwiftLint (400 строк). Порядок типов и полей — дословно по §1,
//  как и в соседнем файле.

import Foundation

public struct MeetingListItem: Codable, Equatable, Sendable {
    public let meetingId: UUID
    public let title: String
    public let start: Date
    public let end: Date
    public let provider: String?
    public let status: MeetingStatus
    public let attendeeCount: Int
    public let isCancelled: Bool
    public let hasRecording: Bool
    public let hasTranscript: Bool

    public init(
        meetingId: UUID, title: String, start: Date, end: Date, provider: String?,
        status: MeetingStatus, attendeeCount: Int, isCancelled: Bool,
        hasRecording: Bool, hasTranscript: Bool
    ) {
        self.meetingId = meetingId
        self.title = title
        self.start = start
        self.end = end
        self.provider = provider
        self.status = status
        self.attendeeCount = attendeeCount
        self.isCancelled = isCancelled
        self.hasRecording = hasRecording
        self.hasTranscript = hasTranscript
    }
}

public struct AudioTrackRef: Codable, Equatable, Sendable {
    public let channel: RecordingManifest.Channel
    public let fileURL: URL

    public init(channel: RecordingManifest.Channel, fileURL: URL) {
        self.channel = channel
        self.fileURL = fileURL
    }
}

public struct RecordingSummary: Codable, Equatable, Sendable {
    public let recordingId: UUID
    public let startedAt: Date
    public let endedAt: Date?
    public let status: RecordingStatus
    public let tracks: [AudioTrackRef]
    public let markers: [RecordingManifest.Marker]
    public let transcripts: [TranscriptHeader]
    public let capturedProcesses: [RecordingManifest.CapturedProcess]

    public init(
        recordingId: UUID, startedAt: Date, endedAt: Date?, status: RecordingStatus,
        tracks: [AudioTrackRef], markers: [RecordingManifest.Marker],
        transcripts: [TranscriptHeader], capturedProcesses: [RecordingManifest.CapturedProcess]
    ) {
        self.recordingId = recordingId
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.tracks = tracks
        self.markers = markers
        self.transcripts = transcripts
        self.capturedProcesses = capturedProcesses
    }
}

public struct MeetingDetail: Codable, Equatable, Sendable {
    public let meeting: MeetingRecord
    public let attendees: [PersonRecord]
    public let organizer: PersonRecord?
    public let recordings: [RecordingSummary]
    public let outputs: [MeetingOutput]

    public init(
        meeting: MeetingRecord, attendees: [PersonRecord], organizer: PersonRecord?,
        recordings: [RecordingSummary], outputs: [MeetingOutput]
    ) {
        self.meeting = meeting
        self.attendees = attendees
        self.organizer = organizer
        self.recordings = recordings
        self.outputs = outputs
    }
}

public struct SpeakerView: Codable, Equatable, Sendable {
    public let cluster: Int
    public let personId: UUID?
    public let displayName: String
    public let confidence: Double
    public let source: AttributionSource
    public let isUncertain: Bool
    public let runnerUpPersonId: UUID?
    public let runnerUpDisplayName: String?
    public let totalMs: Int

    public init(
        cluster: Int, personId: UUID?, displayName: String, confidence: Double,
        source: AttributionSource, isUncertain: Bool, runnerUpPersonId: UUID?,
        runnerUpDisplayName: String?, totalMs: Int
    ) {
        self.cluster = cluster
        self.personId = personId
        self.displayName = displayName
        self.confidence = confidence
        self.source = source
        self.isUncertain = isUncertain
        self.runnerUpPersonId = runnerUpPersonId
        self.runnerUpDisplayName = runnerUpDisplayName
        self.totalMs = totalMs
    }
}

public struct SegmentView: Codable, Equatable, Sendable {
    public let segmentId: Int64
    public let startMs: Int
    public let endMs: Int
    public let channel: RecordingManifest.Channel
    public let cluster: Int?
    public let personId: UUID?
    public let speakerDisplayName: String
    public let text: String
    public let textOriginal: String?
    public let words: [Transcript.Word]
    public let lowConfidenceWordIndexes: [Int]
    public let isUserEdited: Bool

    public init(
        segmentId: Int64, startMs: Int, endMs: Int, channel: RecordingManifest.Channel,
        cluster: Int?, personId: UUID?, speakerDisplayName: String, text: String,
        textOriginal: String?, words: [Transcript.Word], lowConfidenceWordIndexes: [Int],
        isUserEdited: Bool
    ) {
        self.segmentId = segmentId
        self.startMs = startMs
        self.endMs = endMs
        self.channel = channel
        self.cluster = cluster
        self.personId = personId
        self.speakerDisplayName = speakerDisplayName
        self.text = text
        self.textOriginal = textOriginal
        self.words = words
        self.lowConfidenceWordIndexes = lowConfidenceWordIndexes
        self.isUserEdited = isUserEdited
    }
}

public struct TranscriptView: Codable, Equatable, Sendable {
    public let header: TranscriptHeader
    public let recordingId: UUID
    public let speakers: [SpeakerView]
    public let segments: [SegmentView]

    public init(
        header: TranscriptHeader, recordingId: UUID, speakers: [SpeakerView], segments: [SegmentView]
    ) {
        self.header = header
        self.recordingId = recordingId
        self.speakers = speakers
        self.segments = segments
    }
}

public struct ConnectorHealthView: Codable, Equatable, Sendable {
    public let sourceId: CalendarSourceId
    public let displayName: String
    public let isEnabled: Bool
    public let status: ConnectorHealth.Status
    public let message: String?
    public let lastSyncAt: Date?
    public let needsAuthorization: Bool

    public init(
        sourceId: CalendarSourceId, displayName: String, isEnabled: Bool,
        status: ConnectorHealth.Status, message: String?, lastSyncAt: Date?,
        needsAuthorization: Bool
    ) {
        self.sourceId = sourceId
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.status = status
        self.message = message
        self.lastSyncAt = lastSyncAt
        self.needsAuthorization = needsAuthorization
    }
}

public struct RunningJobView: Codable, Equatable, Sendable {
    public let jobId: UUID
    public let type: JobType
    public let meetingId: UUID?
    public let recordingId: UUID?
    public let fraction: Double
    public let stage: String?

    public init(
        jobId: UUID, type: JobType, meetingId: UUID?, recordingId: UUID?,
        fraction: Double, stage: String?
    ) {
        self.jobId = jobId
        self.type = type
        self.meetingId = meetingId
        self.recordingId = recordingId
        self.fraction = fraction
        self.stage = stage
    }
}

public struct ActiveSessionView: Codable, Equatable, Sendable {
    public let recordingId: UUID
    public let meetingId: UUID?
    public let title: String
    public let state: MeetingStatus
    public let startedAt: Date
    public let requestedAppKey: String?
    public let capturedProcesses: [RecordingManifest.CapturedProcess]
    public let containsUnrequested: Bool
    public let micLevel: Float?
    public let systemLevel: Float?

    public init(
        recordingId: UUID, meetingId: UUID?, title: String, state: MeetingStatus, startedAt: Date,
        requestedAppKey: String?, capturedProcesses: [RecordingManifest.CapturedProcess],
        containsUnrequested: Bool, micLevel: Float?, systemLevel: Float?
    ) {
        self.recordingId = recordingId
        self.meetingId = meetingId
        self.title = title
        self.state = state
        self.startedAt = startedAt
        self.requestedAppKey = requestedAppKey
        self.capturedProcesses = capturedProcesses
        self.containsUnrequested = containsUnrequested
        self.micLevel = micLevel
        self.systemLevel = systemLevel
    }
}

/// Готовность обязательных прав. Три значения, потому что состояний три:
/// `.systemAudioRecording` равен `.unknown` до первой записи, и на `.unknown` мастер
/// прав не имеет права рисовать ни «разрешено», ни «запрещено» (C-007). Какие права
/// обязательны — инвариант 25; как получается значение — инвариант 26.
public enum PermissionsReadiness: String, Codable, Sendable {
    case ready
    case notReady
    case unknownUntilFirstUse
}

public struct AppStatus: Codable, Equatable, Sendable {
    public let activeSession: ActiveSessionView?
    public let upcoming: [MeetingListItem]
    public let runningJobs: [RunningJobView]
    public let pendingJobCount: Int
    public let failedJobCount: Int
    public let permissionsReady: PermissionsReadiness
    public let connectors: [ConnectorHealthView]
    public let updatedAt: Date

    public init(
        activeSession: ActiveSessionView?, upcoming: [MeetingListItem],
        runningJobs: [RunningJobView], pendingJobCount: Int, failedJobCount: Int,
        permissionsReady: PermissionsReadiness, connectors: [ConnectorHealthView], updatedAt: Date
    ) {
        self.activeSession = activeSession
        self.upcoming = upcoming
        self.runningJobs = runningJobs
        self.pendingJobCount = pendingJobCount
        self.failedJobCount = failedJobCount
        self.permissionsReady = permissionsReady
        self.connectors = connectors
        self.updatedAt = updatedAt
    }
}
