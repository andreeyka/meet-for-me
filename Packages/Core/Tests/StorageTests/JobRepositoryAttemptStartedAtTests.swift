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

        // Десять строк: одна выигрышная по priority, остальные девять — с
        // ПОПАРНО РАЗЛИЧИМЫМИ значениями attempt_started_at (ни одного
        // повтора, ни одного лишнего nil сверх победителя) и заведомо ниже
        // приоритетом, чтобы решение claimNext зависело только от priority.
        // Различимость нужна для второй половины теста: одинаковые значения
        // не выявили бы случайную сортировку jobs(status:) по этой колонке
        // сравнением списков — а `Set` в прежней версии не выявил бы её и
        // подавно, даже с различимыми значениями, потому что стирает порядок.
        let winner = TestFixtures.job(type: .transcode, options: .init(priority: 99, attemptStartedAt: nil))
        try await jobs.insert(winner)
        var others: [UUID] = []
        for offset in 0..<9 {
            let job = TestFixtures.job(
                type: .transcode,
                options: .init(priority: 1, attemptStartedAt: TestFixtures.epoch.addingTimeInterval(Double(offset)))
            )
            try await jobs.insert(job)
            others.append(job.id)
        }

        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: [], now: TestFixtures.epoch, leaseSeconds: 60
        )
        XCTAssertEqual(picked?.id, winner.id, "выбор не зависит от attempt_started_at — решает priority")

        // Списком, не множеством: jobs(status:) не объявляет ORDER BY по
        // attempt_started_at, и порядок вставки (ROWID) обязан остаться виден
        // как последовательность — сравнение через Set стёрло бы случайную
        // сортировку по этой колонке так же незаметно, как её отсутствие.
        let listing = try await jobs.jobs(status: .pending)
        XCTAssertEqual(
            listing.jobs.map(\.id), others,
            "состав И порядок jobs(status:) не зависят от attempt_started_at"
        )
        XCTAssertTrue(listing.unreadable.isEmpty)
    }
}
