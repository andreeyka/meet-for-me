//  JobQueueStatusInv35Tests — C-016 v13, инв. 35 (а)–(г) (IR-147, MEE-476; задача MEE-477):
//  `status()` читает очередь `JobQueue` — `runningJobs`, `pendingJobCount`, `failedJobCount`.
//  Векторы (35а)–(35г) абзаца «Ломающие изменения против v12». События (д), (е) —
//  `JobQueueEventsInv35Tests.swift`.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

/// Задача очереди для векторов инв. 35: тип выводится из нагрузки, время задаёт тест.
func inv35Job(
    _ payload: JobPayload, status: JobStatus, createdAt seconds: TimeInterval = 0, id: UUID = UUID()
) -> Job {
    let type: JobType
    switch payload {
    case .transcode: type = .transcode
    case .transcribe: type = .transcribe
    case .diarize: type = .diarize
    case .attribute: type = .attribute
    case .summarize: type = .summarize
    }
    let created = Date(timeIntervalSince1970: 1_700_000_000 + seconds)
    return Job(
        id: id, type: type, payload: payload, status: status, priority: 0, attempts: 0, maxAttempts: 3,
        runAfter: created,
        conditions: JobConditions(requiresACPower: false, forbidWhileRecording: false,
                                  maxThermalPressure: .critical, requiresProfileReady: nil),
        dedupKey: nil,
        leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil, createdAt: created, updatedAt: created
    )
}

final class JobQueueStatusInv35Tests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func manifest(recordingId: UUID, meetingId: UUID?) throws -> RecordingManifest {
        try RecordingManifest(
            recordingId: recordingId, meetingId: meetingId, directoryName: recordingId.uuidString,
            startedAt: epoch, endedAt: epoch.addingTimeInterval(600),
            tracks: [
                try RecordingManifest.Track(
                    channel: .mic, fileName: "audio-mic.m4a", sampleRate: 16_000, channelCount: 1, format: "aac-m4a"
                )
            ],
            markers: [], capturedProcesses: [], captureGroupKey: nil,
            inputDevices: [], discontinuities: [], isFinalized: true
        )
    }

    private func saveTranscript(recordingId: UUID, in fixture: FacadeV11Fixture) async throws -> UUID {
        let segment = try Transcript.Segment(
            startMs: 0, endMs: 1_000, channel: .system, speakerCluster: 0,
            text: "текст", textOriginal: nil, textConfidence: 0.9, words: []
        )
        let speaker = try Transcript.Speaker(cluster: 0, embedding: nil, embeddingModelVersion: nil, totalMs: 1_000)
        let header = try await fixture.repositories.transcripts.save(try Transcript(
            recordingId: recordingId, language: "ru", engine: "e", modelVersion: "1", createdAt: epoch,
            segments: [segment], speakers: [speaker]
        ))
        return header.id
    }

    // MARK: - (35а) runningJobs

    /// Идущая `transcribe`: `recordingId` из нагрузки, `meetingId` из манифеста записи,
    /// `stage == nil`, `fraction == 0` до первого `progressed`.
    func test_35a_runningTranscribeTakesMeetingFromManifest() async throws {
        let fixture = FacadeV11Fixture()
        let recordingId = UUID()
        let meetingId = UUID()
        try await fixture.repositories.recordings.save(
            RecordingRecord(manifest: try manifest(recordingId: recordingId, meetingId: meetingId), status: .finalized)
        )
        let job = inv35Job(.transcribe(recordingId: recordingId, profileId: "p", language: nil), status: .running)
        fixture.jobQueue.setJobs([job])

        let status = await fixture.facade.status()

        XCTAssertEqual(status.runningJobs, [
            RunningJobView(jobId: job.id, type: .transcribe, meetingId: meetingId, recordingId: recordingId,
                           fraction: 0, stage: nil)
        ])
    }

    /// Идущая `attribute`: `recordingId` из заголовка транскрипта, `meetingId` из нагрузки.
    func test_35a_runningAttributeTakesRecordingFromTranscriptAndMeetingFromPayload() async throws {
        let fixture = FacadeV11Fixture()
        let recordingId = UUID()
        let payloadMeeting = UUID()
        try await fixture.repositories.recordings.save(
            RecordingRecord(manifest: try manifest(recordingId: recordingId, meetingId: UUID()), status: .finalized)
        )
        let transcriptId = try await saveTranscript(recordingId: recordingId, in: fixture)
        let job = inv35Job(.attribute(transcriptId: transcriptId, meetingId: payloadMeeting), status: .running)
        fixture.jobQueue.setJobs([job])

        let view = await fixture.facade.status().runningJobs.first

        XCTAssertEqual(view?.recordingId, recordingId, "из заголовка транскрипта")
        XCTAssertEqual(view?.meetingId, payloadMeeting, "из нагрузки, а не из манифеста")
        XCTAssertNil(view?.stage)
    }

    /// Нет манифеста — `meetingId == nil`; `summarize` записи не несёт — `recordingId == nil`.
    /// Порядок — `createdAt`, затем `id.uuidString`; не-`running` в список не входят.
    func test_35a_orderAndMissingSources() async throws {
        let fixture = FacadeV11Fixture()
        let low = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
        let high = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
        let summarizeMeeting = UUID()
        let late = inv35Job(.transcode(recordingId: UUID()), status: .running, createdAt: 20)
        let tieHigh = inv35Job(.diarize(recordingId: UUID(), profileId: "p"), status: .running, createdAt: 10, id: high)
        let tieLow = inv35Job(.summarize(meetingId: summarizeMeeting, transcriptId: UUID(), profileId: "p"),
                              status: .running, createdAt: 10, id: low)
        let pending = inv35Job(.transcode(recordingId: UUID()), status: .pending, createdAt: 0)
        fixture.jobQueue.setJobs([late, tieHigh, pending, tieLow])

        let views = await fixture.facade.status().runningJobs

        XCTAssertEqual(views.map(\.jobId), [low, high, late.id])
        XCTAssertEqual(views[0].meetingId, summarizeMeeting)
        XCTAssertNil(views[0].recordingId, "summarize записи не несёт")
        XCTAssertNil(views[2].meetingId, "манифеста нет — nil")
        XCTAssertTrue(views.allSatisfy { $0.stage == nil })
    }

    /// `fraction` — доля последнего `progressed` этой задачи.
    func test_35a_fractionIsLastProgressed() async throws {
        let fixture = FacadeV11Fixture()
        let job = inv35Job(.transcode(recordingId: UUID()), status: .running)
        fixture.jobQueue.setJobs([job])
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.started(jobId: job.id, type: .transcode))
        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: 0.25))
        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: 0.42))
        _ = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        let status = await fixture.facade.status()
        XCTAssertEqual(status.runningJobs.map(\.fraction), [0.42])
    }

    // MARK: - (35б) pendingJobCount

    func test_35b_threePendingJobs() async {
        let fixture = FacadeV11Fixture()
        fixture.jobQueue.setJobs([
            inv35Job(.transcode(recordingId: UUID()), status: .pending),
            inv35Job(.transcode(recordingId: UUID()), status: .pending),
            inv35Job(.diarize(recordingId: UUID(), profileId: "p"), status: .pending),
            inv35Job(.transcode(recordingId: UUID()), status: .succeeded)
        ])

        let status = await fixture.facade.status()

        XCTAssertEqual(status.pendingJobCount, 3)
        XCTAssertEqual(status.failedJobCount, 0)
        XCTAssertEqual(status.runningJobs, [])
    }

    // MARK: - (35в) failedJobCount

    func test_35c_failedRepairedByLaterEqualPayloadIsNotCounted() async {
        let payload = JobPayload.transcribe(recordingId: UUID(), profileId: "p", language: nil)
        for later in [JobStatus.succeeded, .pending, .running] {
            let fixture = FacadeV11Fixture()
            fixture.jobQueue.setJobs([
                inv35Job(payload, status: .failed, createdAt: 0),
                inv35Job(payload, status: later, createdAt: 5)
            ])
            let count = await fixture.facade.status().failedJobCount
            XCTAssertEqual(count, 0, "позже в \(later.rawValue)")
        }
    }

    func test_35c_twoFailuresOfSamePayloadAreBothCounted() async {
        let fixture = FacadeV11Fixture()
        let payload = JobPayload.transcode(recordingId: UUID())
        fixture.jobQueue.setJobs([
            inv35Job(payload, status: .failed, createdAt: 0),
            inv35Job(payload, status: .failed, createdAt: 5)
        ])

        let count = await fixture.facade.status().failedJobCount
        XCTAssertEqual(count, 2)
    }

    /// Не повтор: другая нагрузка, более ранняя задача, `cancelled` — отказ остаётся в счёте.
    func test_35c_failureWithoutLaterRepairStaysCounted() async {
        let fixture = FacadeV11Fixture()
        let payload = JobPayload.transcode(recordingId: UUID())
        fixture.jobQueue.setJobs([
            inv35Job(payload, status: .failed, createdAt: 10),
            inv35Job(payload, status: .succeeded, createdAt: 0),
            inv35Job(payload, status: .cancelled, createdAt: 20),
            inv35Job(.transcode(recordingId: UUID()), status: .succeeded, createdAt: 30)
        ])

        let count = await fixture.facade.status().failedJobCount
        XCTAssertEqual(count, 1)
    }

    // MARK: - (35г) отказ чтения очереди

    func test_35d_queueReadFailureGivesEmptyAndZeros() async {
        let fixture = FacadeV11Fixture()
        fixture.jobQueue.setJobs([
            inv35Job(.transcode(recordingId: UUID()), status: .running),
            inv35Job(.transcode(recordingId: UUID()), status: .pending),
            inv35Job(.transcode(recordingId: UUID()), status: .failed)
        ])
        fixture.jobQueue.failJobs(with: JobQueueError.unknownJob(UUID()))

        let status = await fixture.facade.status()

        XCTAssertEqual(status.runningJobs, [])
        XCTAssertEqual(status.pendingJobCount, 0)
        XCTAssertEqual(status.failedJobCount, 0)
    }
}
