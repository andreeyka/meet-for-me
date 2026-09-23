//  JobRepositoryClaimTests — К37, К38, К39, К40(i) перечня MEE-189, владелец: DEV-2.

import XCTest
import GRDB
import DomainCore
@testable import Storage

final class JobRepositoryClaimTests: StorageAsyncTestCase {

    // MARK: - К40(i) (attempt_started_at снят той же транзакцией, что взят лизинг)

    func testK40i_claimNextClearsStaleAttemptStartedAt() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let stale = TestFixtures.job(type: .transcode, options: .init(attemptStartedAt: TestFixtures.epoch))
        try await jobs.insert(stale)

        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: [], now: TestFixtures.epoch, leaseSeconds: 60
        )
        XCTAssertEqual(picked?.id, stale.id)
        XCTAssertEqual(picked?.status, .running)
        XCTAssertNotNil(picked?.leaseExpiresAt)
        XCTAssertNil(picked?.attemptStartedAt, "снят в той же транзакции, что выставлены running и лизинг")

        let reread = try await jobs.job(id: stale.id)
        XCTAssertNil(reread?.attemptStartedAt)
    }

    // MARK: - К37 (excluding)

    func testK37_excludingSkipsListedCandidates() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let ids = try await Self.insertThreeReadyCandidates(jobs)

        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: [ids[0], ids[1]], now: TestFixtures.epoch, leaseSeconds: 60
        )
        XCTAssertEqual(picked?.id, ids[2])
    }

    func testK37_excludingAllCandidatesGivesNil() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let ids = try await Self.insertThreeReadyCandidates(jobs)

        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: Set(ids), now: TestFixtures.epoch, leaseSeconds: 60
        )
        XCTAssertNil(picked)
        for id in ids {
            let job = try await jobs.job(id: id)
            XCTAssertEqual(job?.status, .pending, "исключённая строка лизинг не берёт")
        }
    }

    func testK37_thousandExcludedIdsDoNotHitVariableLimit() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let ready = TestFixtures.job(type: .transcode)
        try await jobs.insert(ready)

        var excluding = Set((0..<999).map { _ in UUID() })
        excluding.insert(ready.id)
        XCTAssertEqual(excluding.count, 1_000)

        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: excluding, now: TestFixtures.epoch, leaseSeconds: 60
        )
        XCTAssertNil(picked, "вызов не отказывает, единственный кандидат исключён")
    }

    private static func insertThreeReadyCandidates(_ jobs: JobRepository) async throws -> [UUID] {
        let candidates = (0..<3).map { _ in TestFixtures.job(type: .transcode) }
        for job in candidates {
            try await jobs.insert(job)
        }
        return candidates.map(\.id)
    }

    // MARK: - К38 (excluding не влияет ни на что, кроме исключения)

    func testK38_excludingWithUnrelatedIdsChangesNothing() async throws {
        let (firstPick, firstLease) = try await Self.claimFromFreshCorpus(excluding: [])
        let (secondPick, secondLease) = try await Self.claimFromFreshCorpus(
            excluding: [UUID(), UUID()]
        )
        XCTAssertEqual(firstPick, secondPick)
        XCTAssertEqual(firstLease, secondLease)
    }

    private static func claimFromFreshCorpus(excluding: Set<UUID>) async throws -> (String, Date?) {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let winner = TestFixtures.job(type: .transcode, options: .init(priority: 10))
        let loserLowPriority = TestFixtures.job(type: .transcode, options: .init(priority: 1))
        let loserNotDue = TestFixtures.job(
            type: .transcode, options: .init(priority: 50, runAfter: TestFixtures.epoch.addingTimeInterval(3_600))
        )
        let loserNotPending = TestFixtures.job(type: .transcode, status: .running, options: .init(priority: 99))
        for job in [winner, loserLowPriority, loserNotDue, loserNotPending] {
            try await jobs.insert(job)
        }
        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: excluding, now: TestFixtures.epoch, leaseSeconds: 60
        )
        return (picked?.id.uuidString ?? "nil", picked?.leaseExpiresAt)
    }

    // MARK: - К39 (порядок выбора — четыре ключа)

    func testK39_higherPriorityWinsAtEqualRest() async throws {
        let winnerWon = try await Self.claimBetweenTwo(first: .init(priority: 10), second: .init(priority: 5))
        XCTAssertTrue(winnerWon, "больший priority выигрывает")
    }

    func testK39_earlierRunAfterWinsAtEqualPriority() async throws {
        let winnerWon = try await Self.claimBetweenTwo(
            first: .init(runAfter: TestFixtures.epoch),
            second: .init(runAfter: TestFixtures.epoch.addingTimeInterval(1))
        )
        XCTAssertTrue(winnerWon, "меньший runAfter выигрывает при равном priority")
    }

    func testK39_earlierCreatedAtWinsAtEqualPriorityAndRunAfter() async throws {
        let winnerWon = try await Self.claimBetweenTwo(
            first: .init(createdAt: TestFixtures.epoch),
            second: .init(createdAt: TestFixtures.epoch.addingTimeInterval(1))
        )
        XCTAssertTrue(winnerWon, "меньший createdAt выигрывает при равных priority и runAfter")
    }

    func testK39_lexicographicallySmallerIdWinsAtEqualRest() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        var candidates = (0..<2).map { _ in TestFixtures.job(type: .transcode) }
        candidates.sort { $0.id.uuidString < $1.id.uuidString }
        for job in candidates { try await jobs.insert(job) }

        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: [], now: TestFixtures.epoch, leaseSeconds: 60
        )
        XCTAssertEqual(picked?.id, candidates[0].id)
    }

    /// `now` — заведомо позже обоих `runAfter`, иначе разница в `runAfter` иногда
    /// исключала бы кандидата из готовности вместо того, чтобы решать порядок между
    /// двумя готовыми. Возвращает `true`, если выбран кандидат `first`.
    private static func claimBetweenTwo(
        first: TestFixtures.JobOptions, second: TestFixtures.JobOptions
    ) async throws -> Bool {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let winner = TestFixtures.job(type: .transcode, options: first)
        let loser = TestFixtures.job(type: .transcode, options: second)
        try await jobs.insert(winner)
        try await jobs.insert(loser)
        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: [], now: TestFixtures.epoch.addingTimeInterval(10), leaseSeconds: 60
        )
        return picked?.id == winner.id
    }
}
