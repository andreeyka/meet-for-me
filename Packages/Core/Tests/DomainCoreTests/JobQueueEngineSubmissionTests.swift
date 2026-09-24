//  Группа J перечня MEE-189 (постановка, дедуп, значения по умолчанию) — К50, К51, К52.
//  C-013 v8, MEE-350.

import XCTest
import DomainCore
import DomainTestKit

final class JobQueueEngineSubmissionTests: XCTestCase {

    /// К50: `submit` с занятым `dedupKey` не создаёт новую задачу при `pending`/`running`,
    /// создаёт при `failed`.
    func test_k50_submitWithBusyDedupKeyReturnsExistingUnlessTerminal() async throws {
        let rig = JobQueueTestRig()
        await rig.queue.start()

        let firstId = try await rig.queue.submit(makeSubmission(dedupKey: "k"))
        let secondId = try await rig.queue.submit(makeSubmission(dedupKey: "k"))
        XCTAssertEqual(secondId, firstId, "pending: новая задача не создаётся")

        let afterFirst = try await rig.repository.job(id: firstId)
        var job = try XCTUnwrap(afterFirst)
        try await rig.repository.update(Job(
            id: job.id, type: job.type, payload: job.payload, status: .running, priority: job.priority,
            attempts: job.attempts, maxAttempts: job.maxAttempts, runAfter: job.runAfter,
            conditions: job.conditions, dedupKey: job.dedupKey, leaseExpiresAt: rig.clock.now(),
            attemptStartedAt: nil, lastError: nil, createdAt: job.createdAt, updatedAt: rig.clock.now()
        ))
        let thirdId = try await rig.queue.submit(makeSubmission(dedupKey: "k"))
        XCTAssertEqual(thirdId, firstId, "running: новая задача не создаётся")

        let afterThird = try await rig.repository.job(id: firstId)
        job = try XCTUnwrap(afterThird)
        try await rig.repository.update(Job(
            id: job.id, type: job.type, payload: job.payload, status: .failed, priority: job.priority,
            attempts: job.attempts, maxAttempts: job.maxAttempts, runAfter: job.runAfter,
            conditions: job.conditions, dedupKey: job.dedupKey, leaseExpiresAt: nil,
            attemptStartedAt: nil, lastError: "done", createdAt: job.createdAt, updatedAt: rig.clock.now()
        ))
        let fourthId = try await rig.queue.submit(makeSubmission(dedupKey: "k"))
        XCTAssertNotEqual(fourthId, firstId, "failed: создаётся новая задача с новым идентификатором")
    }

    /// К51: `priority` вне `-100...100` даёт `invalidPriority`, задача не создаётся;
    /// границы включены.
    func test_k51_priorityOutOfRangeIsRejected() async throws {
        let rig = JobQueueTestRig()
        await rig.queue.start()

        for rejected in [-101, 101] {
            do {
                _ = try await rig.queue.submit(makeSubmission(priority: rejected))
                XCTFail("ожидался invalidPriority(\(rejected))")
            } catch JobQueueError.invalidPriority(let value) {
                XCTAssertEqual(value, rejected)
            }
        }
        let before = try await rig.queue.jobs(status: .pending).count
        for accepted in [-100, 100, 0] {
            _ = try await rig.queue.submit(makeSubmission(priority: accepted))
        }
        let after = try await rig.queue.jobs(status: .pending).count
        XCTAssertEqual(after - before, 3, "все три границы прошли")
    }

    /// К52: `JobSubmission.standard` — таблица §4 по составу нагрузки, не по перечню типов.
    func test_k52_standardFillsDefaultsFromPayloadComposition() {
        let recordingId = UUID()
        let cases: [StandardDefaultsCase] = [
            StandardDefaultsCase(
                payload: .transcode(recordingId: recordingId), profileId: nil,
                priority: 50, maxAttempts: 3, ac: false, forbid: true, thermal: .serious
            ),
            StandardDefaultsCase(
                payload: .transcribe(recordingId: recordingId, profileId: "p", language: nil), profileId: "p",
                priority: 30, maxAttempts: 3, ac: false, forbid: true, thermal: .fair
            ),
            StandardDefaultsCase(
                payload: .diarize(recordingId: recordingId, profileId: "p"), profileId: "p",
                priority: 20, maxAttempts: 3, ac: false, forbid: true, thermal: .fair
            ),
            StandardDefaultsCase(
                payload: .attribute(transcriptId: UUID(), meetingId: nil), profileId: nil,
                priority: 40, maxAttempts: 3, ac: false, forbid: false, thermal: .serious
            ),
            StandardDefaultsCase(
                payload: .summarize(meetingId: UUID(), transcriptId: UUID(), profileId: "p"), profileId: "p",
                priority: 10, maxAttempts: 2, ac: true, forbid: true, thermal: .fair
            )
        ]
        for testCase in cases {
            let submission = JobSubmission.standard(testCase.payload, runAfter: Date(timeIntervalSince1970: 0))
            XCTAssertEqual(submission.conditions.requiresProfileReady, testCase.profileId)
            XCTAssertEqual(submission.priority, testCase.priority)
            XCTAssertEqual(submission.maxAttempts, testCase.maxAttempts)
            XCTAssertEqual(submission.conditions.requiresACPower, testCase.ac)
            XCTAssertEqual(submission.conditions.forbidWhileRecording, testCase.forbid)
            XCTAssertEqual(submission.conditions.maxThermalPressure, testCase.thermal)
        }
    }

    /// Один вход таблицы §4 для К52 — struct, а не кортеж: `large_tuple` разрешает два члена.
    private struct StandardDefaultsCase {
        let payload: JobPayload
        let profileId: String?
        let priority: Int
        let maxAttempts: Int
        let ac: Bool
        let forbid: Bool
        let thermal: ThermalPressure
    }
}
