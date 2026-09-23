//  JobRepositoryRepairTests — К33, К34, К35, К36 перечня MEE-189, плюс отдельное
//  покрытие `reclaimExpiredLeases` по C-013 v7 (IR-111, МЕЕ-323), владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class JobRepositoryRepairTests: StorageAsyncTestCase {

    // MARK: - К33 (failUnreadable — таблица на шесть входов плюс повтор)

    func testK33_failUnreadableTableOverSixInputsPlusRepeat() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()

        let pendingBroken = try await Self.insertBrokenJob(jobs, temp.database, status: .pending)
        let runningBroken = try await Self.insertBrokenJob(jobs, temp.database, status: .running)
        try await Self.assertRepaired(jobs, temp.database, id: pendingBroken, message: "m1")
        try await Self.assertRepaired(jobs, temp.database, id: runningBroken, message: "m2")

        for status in [JobStatus.succeeded, .failed, .cancelled] {
            let job = TestFixtures.job(status: status)
            try await jobs.insert(job)
            let outcome = try await jobs.failUnreadable(jobId: job.id, message: "x", now: TestFixtures.epoch)
            XCTAssertNil(outcome, "терминальный статус не тронут")
        }

        let unknown = try await jobs.failUnreadable(jobId: UUID(), message: "x", now: TestFixtures.epoch)
        XCTAssertNil(unknown)

        let repeated = try await jobs.failUnreadable(jobId: pendingBroken, message: "other", now: TestFixtures.epoch)
        XCTAssertNil(repeated, "повторный вызов на уже failed строке — без эффекта")
        let afterRepeat = try temp.database.rawRead { db in
            try Row.fetchOne(
                db, sql: "SELECT last_error FROM jobs WHERE id = ?", arguments: [pendingBroken.uuidString]
            )
        }
        let lastError = afterRepeat?["last_error"] as String?
        XCTAssertEqual(lastError, "m1", "повторный вызов не переписал last_error")
    }

    private static func insertBrokenJob(
        _ jobs: JobRepository, _ database: StorageDatabase, status: JobStatus
    ) async throws -> UUID {
        let job = TestFixtures.job(status: status, options: .init(attempts: 1))
        try await jobs.insert(job)
        try database.rawWrite { db in
            try db.execute(
                sql: "UPDATE jobs SET payload_json = 'not-json' WHERE id = ?", arguments: [job.id.uuidString]
            )
        }
        return job.id
    }

    private static func assertRepaired(
        _ jobs: JobRepository, _ database: StorageDatabase, id: UUID, message: String
    ) async throws {
        let type = try await jobs.failUnreadable(jobId: id, message: message, now: TestFixtures.epoch)
        XCTAssertEqual(type, .transcode)
        let row = try database.rawRead { db in
            try Row.fetchOne(db, sql: "SELECT * FROM jobs WHERE id = ?", arguments: [id.uuidString])
        }
        XCTAssertEqual(row?["status"] as String?, "failed")
        XCTAssertEqual(row?["last_error"] as String?, message)
        let updatedAt = row?["updated_at"] as Int64?
        XCTAssertEqual(updatedAt, EpochTime.seconds(TestFixtures.epoch))
        XCTAssertNil(row?["lease_expires_at"] as Int64?)
        XCTAssertEqual(row?["attempts"] as Int?, 1, "attempts не меняется")
        XCTAssertEqual(row?["payload_json"] as String?, "not-json", "испорченный payload_json не чинится")
    }

    // MARK: - К34 (сама колонка type нечитаема)

    func testK34_failUnreadableThrowsWhenTypeColumnItselfIsBroken() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let job = TestFixtures.job(status: .pending)
        try await jobs.insert(job)
        try temp.database.rawWrite { db in
            try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
            try db.execute(sql: "UPDATE jobs SET type = 'bogus' WHERE id = ?", arguments: [job.id.uuidString])
            try db.execute(sql: "PRAGMA ignore_check_constraints = OFF")
        }
        await XCTAssertThrowsErrorAsync(
            _ = try await jobs.failUnreadable(jobId: job.id, message: "m", now: TestFixtures.epoch)
        )
    }

    // MARK: - К35 (jobs(status:) называет, не бросает; суммы сходятся)

    func testK35_jobsStatusNamesUnreadableWithoutThrowing() async throws {
        for status in [JobStatus.pending, .running, .succeeded, .failed, .cancelled] {
            try await Self.assertListingNamesUnreadable(status: status)
        }
    }

    private static func assertListingNamesUnreadable(status: JobStatus) async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let repository = temp.database.jobRepository()
        let valid = (0..<3).map { _ in TestFixtures.job(status: status) }
        let broken = (0..<2).map { _ in TestFixtures.job(status: status) }
        for job in valid + broken { try await repository.insert(job) }
        for job in broken {
            try temp.database.rawWrite { db in
                try db.execute(
                    sql: "UPDATE jobs SET payload_json = 'not-json' WHERE id = ?", arguments: [job.id.uuidString]
                )
            }
        }

        let listing = try await repository.jobs(status: status)
        XCTAssertEqual(listing.jobs.count, 3)
        XCTAssertEqual(listing.unreadable.count, 2)
        XCTAssertEqual(Set(listing.unreadable.map(\.id)), Set(broken.map(\.id)))
        for job in broken {
            let expectedMessage = try await Self.dataCorruptedMessage(repository, id: job.id)
            let named = listing.unreadable.first { $0.id == job.id }
            XCTAssertEqual(named?.message, expectedMessage, "текст дословно совпадает с dataCorrupted.message")
        }

        let rawCount = try temp.database.rawRead { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM jobs WHERE status = ?", arguments: [status.rawValue])
        }
        XCTAssertEqual(listing.jobs.count + listing.unreadable.count, rawCount)
    }

    private static func dataCorruptedMessage(_ jobs: JobRepository, id: UUID) async throws -> String {
        do {
            _ = try await jobs.job(id: id)
            XCTFail("ожидался dataCorrupted")
            return ""
        } catch let error as StorageError {
            guard case .dataCorrupted(_, _, let message) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)")
                return ""
            }
            return message
        }
    }

    // MARK: - К36 (нечитаемый id: jobs(status:) бросает; job(id:) отказывает)

    func testK36_unparseableIdMakesJobsStatusThrow() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        try Self.insertRawPendingJob(temp.database, id: "not-a-uuid")

        await XCTAssertThrowsErrorAsync(_ = try await jobs.jobs(status: .pending))
    }

    func testK36_jobByIdThrowsRatherThanNilOnBrokenRow() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let job = TestFixtures.job()
        try await jobs.insert(job)
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE jobs SET payload_json = 'not-json' WHERE id = ?", arguments: [job.id.uuidString]
            )
        }
        await XCTAssertThrowsErrorAsync(_ = try await jobs.job(id: job.id))
    }

    private static func insertRawPendingJob(_ database: StorageDatabase, id: String) throws {
        try database.rawWrite { db in
            try db.execute(
                sql: """
                INSERT INTO jobs (
                    id, type, payload_json, status, priority, attempts, max_attempts, run_after,
                    requires_ac_power, forbid_while_recording, max_thermal_pressure, created_at, updated_at
                ) VALUES (?, 'transcode', '{}', 'pending', 0, 0, 3, 0, 0, 0, 'fair', 0, 0)
                """,
                arguments: [id]
            )
        }
    }

    // MARK: - reclaimExpiredLeases: C-013 v7 (IR-111) — строки как есть

    func testReclaimExpiredLeasesReturnsRowsUnchanged() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()

        let withMark = TestFixtures.job(status: .running, options: .init(
            attempts: 1, leaseExpiresAt: TestFixtures.epoch, attemptStartedAt: TestFixtures.epoch
        ))
        let withoutMark = TestFixtures.job(status: .running, options: .init(
            leaseExpiresAt: TestFixtures.epoch, attemptStartedAt: nil
        ))
        let notExpired = TestFixtures.job(status: .running, options: .init(
            leaseExpiresAt: TestFixtures.epoch.addingTimeInterval(3_600)
        ))
        for job in [withMark, withoutMark, notExpired] { try await jobs.insert(job) }

        let reclaimed = try await jobs.reclaimExpiredLeases(now: TestFixtures.epoch.addingTimeInterval(1))
        let byId = Dictionary(uniqueKeysWithValues: reclaimed.map { ($0.id, $0) })
        XCTAssertEqual(Set(byId.keys), Set([withMark.id, withoutMark.id]))
        XCTAssertEqual(byId[withMark.id], withMark, "строка возвращена целиком без изменений")
        XCTAssertEqual(byId[withoutMark.id], withoutMark)
        XCTAssertNil(byId[notExpired.id], "лизинг не истёк")
    }
}
