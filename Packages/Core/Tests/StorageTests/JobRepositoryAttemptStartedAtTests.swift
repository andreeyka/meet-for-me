//  JobRepositoryAttemptStartedAtTests — К40(ii)—(iv) перечня MEE-189
//  (инвариант 26 C-010, половина хранилища; C-013 инв. 34), владелец: DEV-2.
//
//  Ш8 (момент приходит значением, не берётся из базы) не требует отдельного
//  фейка часов: `update`/`claimNext`/`reclaimExpiredLeases` уже принимают
//  `now`/`attemptStartedAt` параметром — тест задаёт момент напрямую и
//  сверяет колонку через Ш7, минуя `CURRENT_TIMESTAMP`.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class JobRepositoryAttemptStartedAtTests: StorageAsyncTestCase {

    // MARK: - К40(ii): update с заданным моментом — колонка несёт ровно его

    func testK40ii_updateWritesExactTestClockMomentNotDatabaseTime() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let testClockMoment = TestFixtures.epoch.addingTimeInterval(12_345)

        let job = TestFixtures.job(status: .running)
        try await jobs.insert(job)
        try await jobs.update(TestFixtures.job(
            id: job.id, status: .running, options: .init(attemptStartedAt: testClockMoment)
        ))

        let columnValue = try temp.database.rawRead { db in
            try Int64.fetchOne(
                db, sql: "SELECT attempt_started_at FROM jobs WHERE id = ?", arguments: [job.id.uuidString]
            )
        }
        XCTAssertEqual(columnValue, EpochTime.seconds(testClockMoment), "ровно момент тестовых часов")
    }

    // MARK: - К40(iii): update с attemptStartedAt == nil снимает непустую колонку

    func testK40iii_updateWithNilClearsNonEmptyColumn() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let job = TestFixtures.job(status: .running, options: .init(attemptStartedAt: TestFixtures.epoch))
        try await jobs.insert(job)

        try await jobs.update(TestFixtures.job(id: job.id, status: .running, options: .init(attemptStartedAt: nil)))

        let columnValue = try temp.database.rawRead { db in
            try Int64.fetchOne(
                db, sql: "SELECT attempt_started_at FROM jobs WHERE id = ?", arguments: [job.id.uuidString]
            )
        }
        XCTAssertNil(columnValue)
    }

    // MARK: - К40(iv): claimNext/jobs(status:) не зависят от значений колонки

    func testK40iv_claimNextAndJobsStatusDoNotDependOnAttemptStartedAt() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()

        let jobIds = try await Self.insertTenJobsWithShuffledAttemptStartedAt(jobs: jobs, database: temp.database)

        let winner = try XCTUnwrap(jobIds.min { $0.uuidString < $1.uuidString })
        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: [], now: TestFixtures.epoch, leaseSeconds: 60
        )
        XCTAssertEqual(
            picked?.id, winner,
            "выбор не зависит от attempt_started_at — при равных priority/run_after/created_at решает id"
        )

        // Списком, не множеством: jobs(status:) не объявляет ORDER BY по
        // attempt_started_at, и порядок вставки (ROWID) обязан остаться виден
        // как последовательность — сравнение через Set стёрло бы случайную
        // сортировку по этой колонке так же незаметно, как её отсутствие.
        let expectedRemaining = jobIds.filter { $0 != winner }
        let listing = try await jobs.jobs(status: .pending)
        XCTAssertEqual(
            listing.jobs.map(\.id), expectedRemaining,
            "состав И порядок jobs(status:) не зависят от attempt_started_at"
        )
        XCTAssertTrue(listing.unreadable.isEmpty)
    }

    /// Десять строк с ОДИНАКОВЫМИ priority/run_after/created_at (без
    /// искусственного priority: 99 — все ключи claimNext, кроме id, равны,
    /// так что по К39 выбор сводится к последнему ключу — id ASC) и ПОПАРНО
    /// РАЗЛИЧИМЫМИ attempt_started_at, значения которых НАРОЧНО перемешаны и
    /// НЕ идут в порядке вставки: если бы claimNext или jobs(status:) хоть
    /// как-то зависели от attempt_started_at (например, случайно сортировали
    /// по нему), результат отличался бы от «id ASC»/«порядок вставки» так,
    /// что тест бы это заметил. Значения, растущие вместе с порядком
    /// вставки, такую ошибку не поймали бы — совпадение с правильным ответом
    /// было бы случайным, а не доказательством.
    private static func insertTenJobsWithShuffledAttemptStartedAt(
        jobs: JobRepository, database: StorageDatabase
    ) async throws -> [UUID] {
        var jobIds: [UUID] = []
        for _ in 0..<10 {
            let job = TestFixtures.job(type: .transcode, options: .init(priority: 1))
            try await jobs.insert(job)
            jobIds.append(job.id)
        }
        let shuffledOffsets = [7, 2, 9, 0, 5, 3, 8, 1, 6, 4]
        try database.rawWrite { db in
            for (index, id) in jobIds.enumerated() {
                try db.execute(
                    sql: "UPDATE jobs SET attempt_started_at = ? WHERE id = ?",
                    arguments: [
                        EpochTime.seconds(TestFixtures.epoch.addingTimeInterval(Double(shuffledOffsets[index]))),
                        id.uuidString
                    ]
                )
            }
        }
        return jobIds
    }
}
