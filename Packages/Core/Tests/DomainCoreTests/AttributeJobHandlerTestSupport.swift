//  AttributeJobHandlerTestSupport — общие фикстуры и оснастка тестов
//  `AttributeJobHandler` (C-015 §7 v10, C-013 v13, MEE-415), владелец: DEV-2.

import Foundation
import XCTest
import DomainCore
import DomainTestKit

enum AttributeFixture {
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    /// Минимальный валидный `AppStatus` для `FakeAppFacade` — обработчик его не читает,
    /// нужен только чтобы завести фасад.
    static func appStatus() -> AppStatus {
        AppStatus(
            activeSession: nil, upcoming: [], runningJobs: [], pendingJobCount: 0, failedJobCount: 0,
            permissionsReady: .ready, connectors: [], updatedAt: epoch
        )
    }

    static func permissionSnapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            states: PermissionKind.allCases.map { PermissionState(kind: $0, status: .granted) },
            checkedAt: epoch
        )
    }

    /// `voiceProfilesEnabled` — единственное поле `AppSettings`, которое читает
    /// `AttributeJobHandler` (К33); остальные — валидные заглушки.
    static func settings(voiceProfilesEnabled: Bool) -> AppSettings {
        AppSettings(
            recordingPolicy: .ask, armLeadSeconds: 120, askLeadSeconds: 30,
            missingSignalGraceSeconds: 900, silenceStopSeconds: 300, defaultProfileId: "default",
            processOnACPowerOnly: false, processWhileRecording: false, audioRetentionDays: nil,
            voiceProfilesEnabled: voiceProfilesEnabled, notifyParticipants: false, launchAtLogin: false
        )
    }

    static func word(_ text: String, start: Int = 0, end: Int = 100) throws -> Transcript.Word {
        try Transcript.Word(startMs: start, endMs: end, text: text, confidence: 0.9, original: nil)
    }

    /// `.mic`-канал по умолчанию — без ограничений инварианта 6 C-003 на `speakerCluster`,
    /// которые несёт `.system` при непустом тексте; тестам построения входа кластер не нужен.
    static func segment(
        words: [Transcript.Word], channel: RecordingManifest.Channel = .mic,
        cluster: Int? = nil, start: Int = 0, end: Int = 1_000
    ) throws -> Transcript.Segment {
        try Transcript.Segment(
            startMs: start, endMs: end, channel: channel, speakerCluster: cluster,
            text: words.map(\.text).joined(separator: " "), textOriginal: nil,
            textConfidence: 0.9, words: words
        )
    }

    static func speaker(cluster: Int, embeddingModelVersion: String?) throws -> Transcript.Speaker {
        try Transcript.Speaker(
            cluster: cluster,
            embedding: embeddingModelVersion.map { _ in [Float](repeating: 0.1, count: 4) },
            embeddingModelVersion: embeddingModelVersion, totalMs: 1_000
        )
    }

    static func transcript(
        segments: [Transcript.Segment], speakers: [Transcript.Speaker] = []
    ) throws -> Transcript {
        try Transcript(
            recordingId: UUID(), language: "ru", engine: "engine", modelVersion: "1.0",
            createdAt: epoch, segments: segments, speakers: speakers
        )
    }

    static func person(name: String, email: String, isMe: Bool = false) -> PersonRecord {
        PersonRecord(id: UUID(), displayName: name, emails: [email], isMe: isMe)
    }

    static func meetingEvent(id: UUID, attendees: [MeetingEvent.Attendee]) throws -> MeetingEvent {
        try MeetingEvent(
            id: id, sourceConnectorId: "eventkit", externalId: "ext-\(id.uuidString.prefix(8))",
            icalUid: nil, title: "Standup", start: epoch, end: epoch.addingTimeInterval(1_800),
            timeZone: "UTC", isAllDay: false, isCancelled: false, organizer: nil,
            attendees: attendees, location: nil, bodyText: nil, conference: nil, lastModified: epoch
        )
    }

    static func attendee(person: PersonRecord) throws -> MeetingEvent.Attendee {
        try MeetingEvent.Attendee(
            person: MeetingEvent.Person(name: person.displayName, email: person.emails.first),
            responseStatus: .accepted, isOptional: false
        )
    }

    /// Участник без адреса — К30: не разрешается ни в один `PersonRecord`, выпадает молча.
    static func attendeeWithoutEmail(name: String) throws -> MeetingEvent.Attendee {
        try MeetingEvent.Attendee(
            person: MeetingEvent.Person(name: name, email: nil),
            responseStatus: .accepted, isOptional: false
        )
    }

    static func job(transcriptId: UUID, meetingId: UUID?) -> Job {
        job(payload: .attribute(transcriptId: transcriptId, meetingId: meetingId))
    }

    /// Полный вид, с произвольным `payload` — нужен тестам ветки «чужой payload» (правка
    /// приёмки РП, PR #136, 03:15 UTC), где `job.type == .attribute`, а `payload` — нет.
    static func job(payload: JobPayload) -> Job {
        Job(
            id: UUID(), type: .attribute, payload: payload,
            status: .running, priority: 0, attempts: 0, maxAttempts: 3,
            runAfter: epoch,
            conditions: JobConditions(
                requiresACPower: false, forbidWhileRecording: false,
                maxThermalPressure: .critical, requiresProfileReady: nil
            ),
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil,
            createdAt: epoch, updatedAt: epoch
        )
    }

    static func emptyResult(transcriptId: UUID) -> AttributionResult {
        AttributionResult(
            transcriptId: transcriptId, assignments: [], segmentUpdates: [],
            textCorrections: [], profileUpdates: []
        )
    }
}

/// Собирает `AttributeJobHandler` поверх фейков `DomainTestKit`, с общим `PortCallLog` у всех
/// репозиториев — так критерии, спрашивающие «вызван ли `MeetingRepository`», читают его
/// напрямую, а не гадают по побочным эффектам.
final class AttributeHarness {
    let log = PortCallLog()
    let port = FakeAttributionPort()
    let transcripts: InMemoryTranscriptRepository
    let meetings: InMemoryMeetingRepository
    let persons: InMemoryPersonRepository
    let speakerProfiles: InMemorySpeakerProfileRepository
    let appFacade: FakeAppFacade

    init() {
        transcripts = InMemoryTranscriptRepository(log: log)
        meetings = InMemoryMeetingRepository(log: log)
        persons = InMemoryPersonRepository(log: log)
        speakerProfiles = InMemorySpeakerProfileRepository(log: log)
        appFacade = FakeAppFacade(
            status: AttributeFixture.appStatus(),
            permissions: AttributeFixture.permissionSnapshot(),
            settings: AttributeFixture.settings(voiceProfilesEnabled: true)
        )
    }

    /// Заводит транскрипт через `save(_:)` — идентификатор фейка детерминирован, поэтому
    /// вызывающий получает его обратно и подставляет в `Job.payload.attribute(transcriptId:)`.
    func seedTranscript(_ transcript: Transcript) async throws -> UUID {
        try await transcripts.save(transcript).id
    }

    func handler() -> AttributeJobHandler {
        AttributeJobHandler(
            port: port, transcripts: transcripts, meetings: meetings,
            persons: persons, speakerProfiles: speakerProfiles, appFacade: appFacade
        )
    }

    func run(_ job: Job) async -> JobOutcome {
        await handler().run(job, progress: { _ in })
    }
}

func assertPermanentFailure(
    _ outcome: JobOutcome, file: StaticString = #filePath, line: UInt = #line
) {
    guard case .permanentFailure = outcome else {
        return XCTFail("ожидался .permanentFailure, получено \(outcome)", file: file, line: line)
    }
}

func assertRetry(
    _ outcome: JobOutcome, after seconds: Double, file: StaticString = #filePath, line: UInt = #line
) {
    guard case .retry(let after, _) = outcome else {
        return XCTFail("ожидался .retry, получено \(outcome)", file: file, line: line)
    }
    XCTAssertEqual(after, seconds, file: file, line: line)
}
