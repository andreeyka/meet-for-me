//  MEE-496: повторный `start()` без `stop()` и восстановление по инварианту 10 (C-013 v16).
//
//  Нестабильный К68 (`JobQueueEngineCancelEventsTests`) падал на CI (Linux) лишним
//  `failed(error: "interrupted")` у задачи, которая уже досчиталась успешно или неудачно:
//  восстановление в `start()` читало таблицу, и за время этого `await` своя же задача очереди
//  успевала завершиться — после чего восстановление по устаревшему снимку принимало её за
//  брошенную мёртвым процессом. На macOS окно почти не открывается само, поэтому тест ниже
//  открывает его детерминированно: репозиторий-обёртка, отдав снимок `running`, прежде чем
//  вернуть его очереди, отпускает обработчик и дожидается, пока очередь опустеет.

import XCTest
@testable import DomainCore
import DomainTestKit

final class JobQueueEngineRepeatedStartTests: XCTestCase {

    /// Своя задача, завершившаяся, пока `start()` читал таблицу, восстановлением не
    /// трогается: строка сохраняет настоящий исход, второго финального события нет
    /// (инвариант 15), `attempts` не растёт повторно (инвариант 10 — только для брошенных).
    func test_mee496_repeatedStartDoesNotRecoverOwnJobFinishedDuringSnapshot() async throws {
        let inner = InMemoryJobRepository()
        let repository = SnapshotHookJobRepository(inner: inner)
        let clock = ManualClock()
        let queue = JobQueueEngine(
            repository: repository, modelCatalog: StubModelCatalogPort(),
            powerPort: FakePowerPort(snapshot: .readyDefault), clock: { clock.now() }
        )
        let handler = GatedJobHandler(type: .transcode)
        try await queue.register(handler: handler)
        let iterator = queue.events().makeAsyncIterator()

        await queue.start()   // пустое восстановление; isRunning = true
        // `submit` при запущенной очереди сам проводит пересмотр: к его возврату задача уже
        // `running` в таблице и передана обработчику, который держит её до `release()`.
        let jobId = try await queue.submit(makeSubmission(maxAttempts: 1))

        repository.armRunningSnapshotHook {
            handler.release()
            await queue.waitUntilIdle()
        }
        await queue.start()
        await queue.waitUntilIdle()
        XCTAssertTrue(repository.hookFired, "снимок running обязан был быть прочитан восстановлением")

        let row = try await inner.job(id: jobId)
        XCTAssertEqual(row?.status, .succeeded, "исход задачи не переписан восстановлением")
        XCTAssertEqual(row?.attempts, 1)
        XCTAssertNil(row?.lastError)

        // Метка — тип без обработчика: `submitted` и `blocked`, исполнения нет.
        let markerId = try await queue.submit(
            makeSubmission(payload: .summarize(meetingId: UUID(), transcriptId: UUID(), profileId: "p"), priority: -100)
        )
        var events: [JobEvent] = []
        for _ in 0..<4 {
            guard let event = await nextOrFail(iterator) else { break }
            events.append(event)
        }
        XCTAssertEqual(events.count, 4)
        guard events.count == 4 else { return }
        guard case .submitted(let submittedId, _) = events[0], submittedId == jobId,
              case .started(let startedId, _) = events[1], startedId == jobId,
              case .succeeded(let succeededId, _) = events[2], succeededId == jobId else {
            return XCTFail("ожидалось submitted → started → succeeded задачи, получено \(events)")
        }
        guard case .submitted(let markerSubmittedId, _) = events[3] else {
            return XCTFail("четвёртое событие обязано быть submitted метки, а не второй финал: \(events[3])")
        }
        XCTAssertEqual(markerSubmittedId, markerId)
    }
}

// MARK: - Оснастка

/// Обработчик, который держит задачу, пока тест не позовёт `release()`. Отпущенный до
/// начала `run` — не держит вовсе.
final class GatedJobHandler: JobHandler, @unchecked Sendable {

    let type: JobType
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var isReleased = false

    init(type: JobType) {
        self.type = type
    }

    func run(_ job: Job, progress: @Sendable @escaping (Double) -> Void) async -> JobOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            let resumeNow = isReleased
            if !resumeNow {
                waiter = continuation
            }
            lock.unlock()
            if resumeNow {
                continuation.resume()
            }
        }
        return .success
    }

    func release() {
        lock.lock()
        isReleased = true
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume()
    }
}

/// `InMemoryJobRepository` с крючками на чтение `jobs(status: .running)` (окно гонки MEE-496)
/// и `reclaimExpiredLeases` (то же окно у второго предохранителя, MEE-497): снимок уже взят,
/// крючок зовётся ДО того, как снимок вернётся очереди. Крючки одноразовые.
final class SnapshotHookJobRepository: JobRepository, @unchecked Sendable {

    private let inner: InMemoryJobRepository
    private let lock = NSLock()
    private var hook: (@Sendable () async -> Void)?
    private var fired = false
    private var reclaimHook: (@Sendable () async -> Void)?
    private var reclaimFired = false

    init(inner: InMemoryJobRepository) {
        self.inner = inner
    }

    func armRunningSnapshotHook(_ body: @escaping @Sendable () async -> Void) {
        lock.lock()
        hook = body
        lock.unlock()
    }

    var hookFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func armReclaimHook(_ body: @escaping @Sendable () async -> Void) {
        lock.lock()
        reclaimHook = body
        lock.unlock()
    }

    var reclaimHookFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reclaimFired
    }

    private func takeReclaimHook() -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let taken = reclaimHook
        reclaimHook = nil
        if taken != nil {
            reclaimFired = true
        }
        return taken
    }

    private func takeHook() -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        let taken = hook
        hook = nil
        if taken != nil {
            fired = true
        }
        return taken
    }

    func insert(_ job: Job) async throws {
        try await inner.insert(job)
    }

    func update(_ job: Job) async throws {
        try await inner.update(job)
    }

    func job(id: UUID) async throws -> Job? {
        try await inner.job(id: id)
    }

    func jobs(status: JobStatus) async throws -> JobListing {
        let listing = try await inner.jobs(status: status)
        if status == .running, let hook = takeHook() {
            await hook()
        }
        return listing
    }

    func activeJob(dedupKey: String) async throws -> Job? {
        try await inner.activeJob(dedupKey: dedupKey)
    }

    func claimNext(types: [JobType], excluding: Set<UUID>, now: Date, leaseSeconds: Int) async throws -> Job? {
        try await inner.claimNext(types: types, excluding: excluding, now: now, leaseSeconds: leaseSeconds)
    }

    func reclaimExpiredLeases(now: Date) async throws -> [Job] {
        let stale = try await inner.reclaimExpiredLeases(now: now)
        if let hook = takeReclaimHook() {
            await hook()
        }
        return stale
    }

    func failUnreadable(jobId: UUID, message: String, now: Date) async throws -> JobType? {
        try await inner.failUnreadable(jobId: jobId, message: message, now: now)
    }
}
