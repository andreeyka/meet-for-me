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
