//  JobRepositoryTests — К10 (половина jobs), К41, К42, К45 перечня MEE-189,
//  владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class JobRepositoryTests: StorageAsyncTestCase {

    // MARK: - К10 (частичный уникальный индекс jobs.dedup_key)

    func testK10a_pendingRowBlocksSameDedupKey() async throws {
        try await assertDedupBlocks(existing: .pending)
    }

    func testK10b_runningRowBlocksSameDedupKey() async throws {
        try await assertDedupBlocks(existing: .running)
    }

    func testK10c_failedRowDoesNotBlockSameDedupKey() async throws {
        try await assertDedupAllows(existing: [.failed])
    }

    func testK10d_succeededAndCancelledDoNotBlockSameDedupKey() async throws {
        try await assertDedupAllows(existing: [.succeeded, .cancelled])
    }

    private func assertDedupBlocks(existing: JobStatus) async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        try await jobs.insert(TestFixtures.job(status: existing, options: .init(dedupKey: "k")))
        await XCTAssertThrowsErrorAsync(
            try await jobs.insert(TestFixtures.job(status: .pending, options: .init(dedupKey: "k")))
        )
    }

    private func assertDedupAllows(existing: [JobStatus]) async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        for status in existing {
            try await jobs.insert(TestFixtures.job(status: status, options: .init(dedupKey: "k")))
        }
        try await jobs.insert(TestFixtures.job(status: .pending, options: .init(dedupKey: "k")))
    }

    // MARK: - К41 (JobConditions.requiresProfileReady, круг запись → чтение)

    func testK41_requiresProfileReadyRoundTripsAndStoresRawColumn() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()

        let withProfile = TestFixtures.job(options: .init(
            conditions: JobConditions(
                requiresACPower: true, forbidWhileRecording: true,
                maxThermalPressure: .serious, requiresProfileReady: "p1"
            )
        ))
        let withoutProfile = TestFixtures.job(options: .init(
            conditions: JobConditions(
                requiresACPower: false, forbidWhileRecording: false,
                maxThermalPressure: .fair, requiresProfileReady: nil
            )
        ))
        try await jobs.insert(withProfile)
        try await jobs.insert(withoutProfile)

        let readWithProfile = try await jobs.job(id: withProfile.id)
        let readWithoutProfile = try await jobs.job(id: withoutProfile.id)
        XCTAssertEqual(readWithProfile?.conditions, withProfile.conditions)
        XCTAssertEqual(readWithoutProfile?.conditions, withoutProfile.conditions)

        try temp.database.rawRead { db in
            let withProfileRow = try Row.fetchOne(
                db, sql: "SELECT requires_profile_ready FROM jobs WHERE id = ?",
                arguments: [withProfile.id.uuidString]
            )
            let withProfileValue = withProfileRow?["requires_profile_ready"] as String?
            XCTAssertEqual(withProfileValue, "p1")
            let withoutProfileRow = try Row.fetchOne(
                db, sql: "SELECT requires_profile_ready FROM jobs WHERE id = ?",
                arguments: [withoutProfile.id.uuidString]
            )
            let withoutProfileValue = withoutProfileRow?["requires_profile_ready"] as String?
            XCTAssertNil(withoutProfileValue)
        }
    }

    // MARK: - К42 (attemptStartedAt, круг запись → чтение)

    func testK42_attemptStartedAtRoundTripsNilAndSet() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()

        let withMark = TestFixtures.job(status: .running, options: .init(attemptStartedAt: TestFixtures.epoch))
        let withoutMark = TestFixtures.job(options: .init(attemptStartedAt: nil))
        try await jobs.insert(withMark)
        try await jobs.insert(withoutMark)

        let readWithMark = try await jobs.job(id: withMark.id)
        let readWithoutMark = try await jobs.job(id: withoutMark.id)
        XCTAssertEqual(readWithMark?.attemptStartedAt, TestFixtures.epoch)
        XCTAssertNil(readWithoutMark?.attemptStartedAt)

        let updated = TestFixtures.job(
            id: withMark.id, status: .pending, options: .init(attemptStartedAt: nil)
        )
        try await jobs.update(updated)
        let readAfterUpdate = try await jobs.job(id: withMark.id)
        XCTAssertNil(readAfterUpdate?.attemptStartedAt)
    }

    // MARK: - К45 (правило UUID: верхний регистр при записи, любой при чтении)

    func testK45_payloadUUIDWrittenUppercaseReadCaseInsensitive() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()

        let recordingId = UUID()
        let job = TestFixtures.job(payload: .transcode(recordingId: recordingId))
        try await jobs.insert(job)

        let payloadText = try temp.database.rawRead { db in
            try String.fetchOne(db, sql: "SELECT payload_json FROM jobs WHERE id = ?", arguments: [job.id.uuidString])
        }
        let payload = try XCTUnwrap(payloadText)
        XCTAssertTrue(payload.contains(recordingId.uuidString.uppercased()), "UUID пишется верхним регистром")

        let lowered = payload.replacingOccurrences(
            of: recordingId.uuidString.uppercased(), with: recordingId.uuidString.lowercased()
        )
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE jobs SET payload_json = ? WHERE id = ?", arguments: [lowered, job.id.uuidString]
            )
        }

        let reread = try await jobs.job(id: job.id)
        XCTAssertEqual(reread?.payload, .transcode(recordingId: recordingId), "нижний регистр читается без ошибки")
    }
}
