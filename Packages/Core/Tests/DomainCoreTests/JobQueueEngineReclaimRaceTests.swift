//  MEE-497: второй предохранитель лизинга (`reclaimExpiredLeases`, инвариант 11) и своя
//  задача очереди, досчитавшаяся за время чтения таблицы (C-013 v16).
//
//  Та же гонка, что MEE-496 закрыл в восстановлении `start()`: фильтр «своё» проверялся
//  ПОСЛЕ `await repository.reclaimExpiredLeases`. Своя задача с истёкшим лизингом (часы
//  скакнули после сна ноутбука), завершившаяся за время этого `await`, выглядела брошенной —
//  и её строка переписывалась на `attempts + 1`/`"interrupted"` поверх настоящего исхода.
//  Тест открывает окно детерминированно: репозиторий-обёртка, отдав снимок, прежде чем
//  вернуть его очереди, отпускает обработчик и дожидается, пока очередь снимет задачу из
//  исполняемых.

import XCTest
@testable import DomainCore
import DomainTestKit

final class JobQueueEngineReclaimRaceTests: XCTestCase {

    /// Своя задача с истёкшим лизингом, досчитавшаяся, пока заход читал истёкшие лизинги,
    /// вторым предохранителем не трогается: строка сохраняет настоящий исход.
    func test_mee497_reclaimDoesNotOverwriteOwnJobFinishedDuringSnapshot() async throws {
        let inner = InMemoryJobRepository()
        let repository = SnapshotHookJobRepository(inner: inner)
        let clock = ManualClock()
        // Лизинг 10 с, а не 60: сторож продлевает лизинг, лишь когда с прошлого продления
        // прошло ≥ 30 с по часам очереди (`renewLeaseWhileRunning`). Со сдвигом часов на 15 с
        // лизинг уже истёк (10 < 15), а сторожу до продления ещё далеко (10 + 5 < 30), —
        // иначе он мог бы продлить лизинг раньше чтения и закрыть окно недетерминированно.
        let queue = JobQueueEngine(
            repository: repository, modelCatalog: StubModelCatalogPort(),
            powerPort: FakePowerPort(snapshot: .readyDefault), clock: { clock.now() },
            leaseSeconds: 10
        )
        let handler = GatedJobHandler(type: .transcode)
        try await queue.register(handler: handler)

        await queue.start()   // пустое восстановление; isRunning = true
        // `submit` при запущенной очереди сам проводит пересмотр: к его возврату задача уже
        // `running` в таблице и передана обработчику, который держит её до `release()`.
        let jobId = try await queue.submit(makeSubmission(maxAttempts: 1))
        let startedRow = try await inner.job(id: jobId)
        XCTAssertEqual(startedRow?.status, .running)
        XCTAssertEqual(startedRow?.leaseExpiresAt, clock.now().addingTimeInterval(10))

        clock.advance(by: 15)   // часы скакнули: лизинг своей бегущей задачи истёк

        repository.armReclaimHook {
            handler.release()
            await queue.waitUntilNotExecutingForTest(jobId)
        }
        await queue.performRevisitSweepForTest(withPendingRequest: false)
        await queue.waitUntilIdle()
        XCTAssertTrue(repository.reclaimHookFired, "истёкшие лизинги обязаны были быть прочитаны заходом")

        let row = try await inner.job(id: jobId)
        XCTAssertEqual(row?.status, .succeeded, "исход задачи не переписан вторым предохранителем")
        XCTAssertEqual(row?.attempts, 1)
        XCTAssertNil(row?.lastError)
    }
}

// MARK: - Оснастка

extension JobQueueEngine {

    /// Дождаться, пока задача уйдёт из `runningTasks` (исход записан, `executeAndFinish`
    /// снял её). Опрос с потолком ~5 с: не дождались — тест упадёт на проверке строки.
    func waitUntilNotExecutingForTest(_ jobId: UUID) async {
        for _ in 0..<5_000 {
            guard runningTasks[jobId] != nil else { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }
}
