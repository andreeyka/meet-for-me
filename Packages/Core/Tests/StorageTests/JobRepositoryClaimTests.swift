//  JobRepositoryClaimTests — К37, К38, К39, К40(i), К90 перечня MEE-189, владелец: DEV-2.

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

    /// Каждый прогон строит свой собственный корпус со свежими `id` — сравнивать
    /// пришлось бы `id` через разные базы, что всегда не совпадёт. Вместо этого
    /// сверяется структурная примета победителя (`priority == 10`, единственный
    /// такой в корпусе) и смещение лизинга от `now`, а не сырой `id`/`leaseExpiresAt`.
    ///
    /// Текст правлен дельтой `С` MEE-189 (C-010 v13, IR-121, MEE-356): `run_after`
    /// больше не участвует в фильтре `claimNext`, только в порядке (К39/К90). Корпус
    /// не варьирует его значение между двумя прогонами нарочно, чтобы не смешивать
    /// вопрос об `excluding` (единственный предмет этого критерия) с вопросом о
    /// порядке — `loserFuture` несёт будущий `runAfter`, но проигрывает по `priority`,
    /// как и прочие «loser»-кандидаты, а не потому, что отфильтрован.
    func testK38_excludingWithUnrelatedIdsChangesNothing() async throws {
        let first = try await Self.claimFromFreshCorpus(excluding: [])
        let second = try await Self.claimFromFreshCorpus(excluding: [UUID(), UUID()])
        XCTAssertEqual(first?.priority, 10, "выбран один и тот же кандидат по priority")
        XCTAssertEqual(second?.priority, 10)
        XCTAssertEqual(first?.leaseOffset, second?.leaseOffset, "lease_expires_at выставлен одинаково")
    }

    private struct ClaimOutcome {
        let priority: Int
        let leaseOffset: TimeInterval?
    }

    private static func claimFromFreshCorpus(excluding: Set<UUID>) async throws -> ClaimOutcome? {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let winner = TestFixtures.job(type: .transcode, options: .init(priority: 10))
        let loserLowPriority = TestFixtures.job(type: .transcode, options: .init(priority: 1))
        let loserFuture = TestFixtures.job(
            type: .transcode, options: .init(priority: 2, runAfter: TestFixtures.epoch.addingTimeInterval(3_600))
        )
        let loserNotPending = TestFixtures.job(type: .transcode, status: .running, options: .init(priority: 99))
        for job in [winner, loserLowPriority, loserFuture, loserNotPending] {
            try await jobs.insert(job)
        }
        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: excluding, now: TestFixtures.epoch, leaseSeconds: 60
        )
        guard let picked else { return nil }
        let offset = picked.leaseExpiresAt.map { $0.timeIntervalSince(TestFixtures.epoch) }
        return ClaimOutcome(priority: picked.priority, leaseOffset: offset)
    }

    // MARK: - К90 (run_after не фильтрует — кандидат из будущего остаётся полноправным)

    /// C-010 v13 инв. 25, третья клауза (IR-121, MEE-356; дельта `С` MEE-189, К90):
    /// кандидат с `run_after` в будущем — полноправный участник выбора; решает только
    /// `priority` (инвариант 3 C-013, та же ступень, что проверяет К39). Готовность по
    /// времени (`run_after <= now`) этот метод не проверяет вовсе — её проверяет
    /// очередь над уже взятым кандидатом (`JobBlockReason.notYetDue`, C-013 инв. 4).
    func testK90_futureRunAfterDoesNotExcludeHigherPriorityCandidate() async throws {
        let temp = try StorageTestSupport.makeDatabase()
        defer { StorageTestSupport.cleanup(temp) }
        let jobs = temp.database.jobRepository()
        let candidateA = TestFixtures.job(
            type: .transcode, options: .init(priority: 10, runAfter: TestFixtures.epoch.addingTimeInterval(3_600))
        )
        let candidateB = TestFixtures.job(type: .transcode, options: .init(priority: 5))
        try await jobs.insert(candidateA)
        try await jobs.insert(candidateB)

        let picked = try await jobs.claimNext(
            types: [.transcode], excluding: [], now: TestFixtures.epoch, leaseSeconds: 60
        )
        XCTAssertEqual(picked?.id, candidateA.id, "run_after в будущем не отфильтровал кандидата А")
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

    /// Устаревший довод снят MEE-357 (C-010 v13, IR-121): `run_after` с v11 не фильтр
    /// `claimNext`, а только ступень порядка (К90) — «исключить из готовности» здесь
    /// больше не про что. Смещение `now` на +10 сохранено без функциональной нужды —
    /// не мешает и не требует правки самого входа. Возвращает `true`, если выбран
    /// кандидат `first`.
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
