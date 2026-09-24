//  JobRepositoryDataCorruptedTests — К30 перечня MEE-189 (инвариант 21,
//  JobRepository), владелец: DEV-2.
//
//  К30 говорит «девять методов порта», а объявление `JobRepository` (§3
//  C-013 v7) несёт восемь: `insert`, `update`, `job(id:)`, `jobs(status:)`,
//  `activeJob(dedupKey:)`, `claimNext(...)`, `reclaimExpiredLeases(now:)`,
//  `failUnreadable(...)`. Число не сходится — не решаю за контракт, называю
//  в отчёте части. Из восьми пять вообще МОГУТ столкнуться со строкой,
//  битой по `payload_json`, на входе К30 (одна битая строка jobs, остальные
//  методы не читают её): `insert`/`update` пишут целый `Job`, ничего не
//  разбирая; `failUnreadable` — единственный метод порта, документированно
//  не разбирающий `payload_json` (К33). Проверены все пять применимых.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class JobRepositoryDataCorruptedTests: StorageAsyncTestCase {

    func testK30_jobByIdGivesDataCorrupted() async throws {
        let broken = try await Self.makeBrokenJob()
        defer { StorageTestSupport.cleanup(broken.temp) }
        try await Self.assertDataCorrupted(id: broken.id) { try await broken.jobs.job(id: broken.id) }
    }

    func testK30_activeJobGivesDataCorrupted() async throws {
        let broken = try await Self.makeBrokenJob(dedupKey: "k30-dedup")
        defer { StorageTestSupport.cleanup(broken.temp) }
        try await Self.assertDataCorrupted(id: broken.id) {
            try await broken.jobs.activeJob(dedupKey: "k30-dedup")
        }
    }

    func testK30_claimNextGivesDataCorrupted() async throws {
        let broken = try await Self.makeBrokenJob()
        defer { StorageTestSupport.cleanup(broken.temp) }
        try await Self.assertDataCorrupted(id: broken.id) {
            try await broken.jobs.claimNext(
                types: [.transcode], excluding: [], now: TestFixtures.epoch, leaseSeconds: 60
            )
        }
    }

    func testK30_reclaimExpiredLeasesGivesDataCorrupted() async throws {
        let broken = try await Self.makeBrokenJob(
            status: .running, options: .init(leaseExpiresAt: TestFixtures.epoch)
        )
        defer { StorageTestSupport.cleanup(broken.temp) }
        try await Self.assertDataCorrupted(id: broken.id) {
            try await broken.jobs.reclaimExpiredLeases(now: TestFixtures.epoch.addingTimeInterval(1))
        }
    }

    /// Девятый метод по тексту К30, `jobs(status:)` — единственный, который
    /// не бросает, а называет строку (К35): проверяется здесь тем же входом,
    /// чтобы явно закрыть весь список, которым бы он ни был числом.
    func testK30_jobsStatusNamesRatherThanThrows() async throws {
        let broken = try await Self.makeBrokenJob()
        defer { StorageTestSupport.cleanup(broken.temp) }
        let listing = try await broken.jobs.jobs(status: .pending)
        XCTAssertTrue(listing.jobs.isEmpty)
        XCTAssertEqual(listing.unreadable.map(\.id), [broken.id])
    }

    // MARK: - Оснастка

    private struct BrokenJob {
        let temp: StorageTestSupport.TemporaryDatabase
        let jobs: JobRepository
        let id: UUID
    }

    private static func makeBrokenJob(
        status: JobStatus = .pending, dedupKey: String? = nil, options: TestFixtures.JobOptions = .init()
    ) async throws -> BrokenJob {
        let temp = try StorageTestSupport.makeDatabase()
        let jobs = temp.database.jobRepository()
        var jobOptions = options
        jobOptions.dedupKey = dedupKey
        let job = TestFixtures.job(status: status, options: jobOptions)
        try await jobs.insert(job)
        try temp.database.rawWrite { db in
            try db.execute(
                sql: "UPDATE jobs SET payload_json = 'not-json' WHERE id = ?", arguments: [job.id.uuidString]
            )
        }
        return BrokenJob(temp: temp, jobs: jobs, id: job.id)
    }

    private static func assertDataCorrupted<T>(
        id: UUID, file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
    ) async throws {
        do {
            _ = try await body()
            XCTFail("ожидался dataCorrupted", file: file, line: line)
        } catch let error as StorageError {
            guard case .dataCorrupted(let entity, let namedId, _) = error else {
                XCTFail("ожидался dataCorrupted, получено \(error)", file: file, line: line); return
            }
            XCTAssertEqual(entity, "Job", file: file, line: line)
            XCTAssertEqual(namedId, id.uuidString, "id — строки, а не заглушка", file: file, line: line)
        }
    }
}
