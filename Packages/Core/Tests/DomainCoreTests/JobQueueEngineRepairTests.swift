//  Группа P перечня MEE-189 (нечитаемая строка: что делает очередь) — К79…К83. C-013 v8,
//  MEE-350.

import XCTest
import DomainCore
import DomainTestKit

final class JobQueueEngineRepairTests: XCTestCase {

    /// К79: `dataCorrupted` не останавливает очередь — битая строка помечена `failed` с
    /// текстом отказа дословно, соседняя задача исполняется, `attempts` битой не изменён.
    func test_k79_dataCorruptedIsRepairedAndTheReviewContinues() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .attribute)
        try await rig.queue.register(handler: handler)

        let badId = UUID()
        let bad = makeRunningRow(
            type: .transcode, attempts: 1, maxAttempts: 3, attemptStartedAt: nil, leaseExpiresAt: nil
        )
        try await rig.repository.insert(Job(
            id: badId, type: bad.type, payload: bad.payload, status: .pending, priority: 50,
            attempts: 1, maxAttempts: 3, runAfter: rig.clock.now(), conditions: bad.conditions,
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil,
            createdAt: rig.clock.now(), updatedAt: rig.clock.now()
        ))
        let message = "payload_json: unexpected end of data"
        rig.repository.markUnreadable(
            jobId: badId, error: .dataCorrupted(entity: "Job", id: badId.uuidString, message: message)
        )

        let goodId = try await rig.queue.submit(makeSubmission(
            payload: .attribute(transcriptId: UUID(), meetingId: nil), priority: 10
        ))

        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()
        await rig.queue.start()
        await rig.queue.waitUntilIdle()

        var sawFailed = false
        for _ in 0..<6 {
            guard let event = await nextEventOrNil(&iterator) else { break }
            if case .failed(let id, let type, let error, let willRetry) = event, id == badId {
                XCTAssertEqual(type, .transcode)
                XCTAssertEqual(error, message, "текст dataCorrupted дословно, без усечения")
                XCTAssertFalse(willRetry)
                sawFailed = true
            }
        }
        XCTAssertTrue(sawFailed)

        XCTAssertEqual(rig.repository.failUnreadableCallCount, 1)
        let good = try await rig.repository.job(id: goodId)
        XCTAssertEqual(good?.status, .succeeded, "соседняя задача исполнилась")
    }

    /// К80: `job(id:)` на нечитаемой строке в терминальном статусе — `failUnreadable`
    /// возвращает `nil`, повтор даёт тот же `id`, цикл прекращён, отказ ушёл наружу.
    func test_k80_repairCycleTerminatesOnTerminalUnreadableRow() async throws {
        let rig = JobQueueTestRig()
        let jobId = UUID()
        let job = makeRunningRow(attempts: 0, maxAttempts: 3, attemptStartedAt: nil, leaseExpiresAt: nil)
        try await rig.repository.update(Job(
            id: jobId, type: job.type, payload: job.payload, status: .failed, priority: 0,
            attempts: 3, maxAttempts: 3, runAfter: rig.clock.now(), conditions: job.conditions,
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: "already failed",
            createdAt: rig.clock.now(), updatedAt: rig.clock.now()
        ))
        let message = "still corrupted"
        rig.repository.markUnreadable(
            jobId: jobId, error: .dataCorrupted(entity: "Job", id: jobId.uuidString, message: message)
        )

        do {
            _ = try await rig.queue.job(id: jobId)
            XCTFail("ожидался StorageError.dataCorrupted")
        } catch StorageError.dataCorrupted(let entity, let id, let text) {
            XCTAssertEqual(entity, "Job")
            XCTAssertEqual(id, jobId.uuidString)
            XCTAssertEqual(text, message)
        }
        XCTAssertEqual(
            rig.repository.failUnreadableCallCount, 1,
            "failUnreadable звана один раз — на failed-строке она вернула nil, и цикл прекращён"
        )
    }

    /// К81: `jobs(status:)` называет нечитаемые строки — при `pending`/`running` очередь
    /// зовёт `failUnreadable` по каждой и публикует `failed`, исходный вызов НЕ повторяет; на
    /// терминальных статусах не зовёт ничего и не публикует ничего.
    func test_k81_namedUnreadableRowsAreRepairedOnlyForNonTerminalStatuses() async throws {
        let rig = JobQueueTestRig()

        let pendingBadId = UUID()
        try await rig.repository.insert(makeUnreadableRow(id: pendingBadId, status: .pending, now: rig.clock.now()))
        rig.repository.markUnreadable(
            jobId: pendingBadId,
            error: .dataCorrupted(entity: "Job", id: pendingBadId.uuidString, message: "bad pending")
        )

        let failedBadId = UUID()
        try await rig.repository.insert(makeUnreadableRow(id: failedBadId, status: .failed, now: rig.clock.now()))
        rig.repository.markUnreadable(
            jobId: failedBadId,
            error: .dataCorrupted(entity: "Job", id: failedBadId.uuidString, message: "bad failed")
        )

        let stream = rig.queue.events()
        var iterator = stream.makeAsyncIterator()

        let pendingListing = try await rig.queue.jobs(status: .pending)
        XCTAssertFalse(pendingListing.contains { $0.id == pendingBadId }, "нечитаемая наружу не выходит")
        guard case .failed(let id, _, let error, let willRetry) = await nextEventOrNil(&iterator) else {
            return XCTFail("ожидался failed на pending-строке")
        }
        XCTAssertEqual(id, pendingBadId)
        XCTAssertEqual(error, "bad pending")
        XCTAssertFalse(willRetry)
        XCTAssertEqual(rig.repository.failUnreadableCallCount, 1)

        let failedListing = try await rig.queue.jobs(status: .failed)
        XCTAssertFalse(failedListing.contains { $0.id == failedBadId })
        XCTAssertEqual(
            rig.repository.failUnreadableCallCount, 1,
            "терминальный статус — failUnreadable не звана снова"
        )
    }

    /// К82: `JobQueue.jobs(status:)` не отдаёт нечитаемые строки ни при каком статусе.
    func test_k82_unreadableRowsNeverLeaveTheQueue() async throws {
        let rig = JobQueueTestRig()
        for status: JobStatus in [.pending, .failed] {
            let badId = UUID()
            try await rig.repository.insert(makeUnreadableRow(id: badId, status: status, now: rig.clock.now()))
            rig.repository.markUnreadable(
                jobId: badId, error: .dataCorrupted(entity: "Job", id: badId.uuidString, message: "m")
            )
            let listing = try await rig.queue.jobs(status: status)
            XCTAssertFalse(listing.contains { $0.id == badId })
        }
    }

    /// К83: `entity != "Job"` либо `id`, не разбирающийся в `UUID`, — ремонт невозможен:
    /// `failUnreadable` не звана ни разу, отказ ушёл вызывающей стороне.
    func test_k83_repairIsImpossibleForForeignEntityOrUnparsableId() async throws {
        let rig = JobQueueTestRig()
        let handler = FakeJobHandler(type: .transcode)
        try await rig.queue.register(handler: handler)

        let foreignId = UUID()
        try await rig.repository.insert(makeUnreadableRow(id: foreignId, status: .pending, now: rig.clock.now()))
        rig.repository.markUnreadable(
            jobId: foreignId,
            error: .dataCorrupted(entity: "Recording", id: foreignId.uuidString, message: "чужая сущность")
        )
        do {
            _ = try await rig.queue.job(id: foreignId)
            XCTFail("ожидался dataCorrupted")
        } catch StorageError.dataCorrupted(let entity, _, _) {
            XCTAssertEqual(entity, "Recording")
        }
        XCTAssertEqual(rig.repository.failUnreadableCallCount, 0)

        let unparsableId = UUID()
        try await rig.repository.insert(makeUnreadableRow(id: unparsableId, status: .pending, now: rig.clock.now()))
        rig.repository.markUnreadable(
            jobId: unparsableId,
            error: .dataCorrupted(entity: "Job", id: "не-uuid", message: "id не разбирается")
        )
        do {
            _ = try await rig.queue.job(id: unparsableId)
            XCTFail("ожидался dataCorrupted")
        } catch StorageError.dataCorrupted(let entity, let id, _) {
            XCTAssertEqual(entity, "Job")
            XCTAssertEqual(id, "не-uuid")
        }
        XCTAssertEqual(rig.repository.failUnreadableCallCount, 0)
    }

    // MARK: - Оснастка

    private func makeUnreadableRow(id: UUID, status: JobStatus, now: Date) -> Job {
        Job(
            id: id, type: .transcode, payload: .transcode(recordingId: UUID()), status: status,
            priority: 0, attempts: 1, maxAttempts: 3, runAfter: now,
            conditions: JobConditions(
                requiresACPower: false, forbidWhileRecording: false,
                maxThermalPressure: .critical, requiresProfileReady: nil
            ),
            dedupKey: nil, leaseExpiresAt: nil, attemptStartedAt: nil, lastError: nil,
            createdAt: now, updatedAt: now
        )
    }

    private func nextEventOrNil(_ iterator: inout AsyncStream<JobEvent>.AsyncIterator) async -> JobEvent? {
        await iterator.next()
    }
}
