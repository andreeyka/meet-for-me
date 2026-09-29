//  JobQueueLifecycleInv35Tests — C-016 v13, инв. 35 (д), (е) и 31 (IR-147; задача MEE-477):
//  жизненный цикл задачи и потока очереди глазами фасада — повторная попытка, завершение
//  задачи, завершение потока `JobQueue.events()`, порядок `failure` и `statusChanged`.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class JobQueueLifecycleInv35Tests: XCTestCase {

    private func progressed(_ events: [AppEvent]) -> [Double] {
        events.compactMap { event in
            if case let .jobProgressed(_, _, fraction) = event { return fraction }
            return nil
        }
    }

    private func isStatusChanged(_ event: AppEvent) -> Bool {
        if case .statusChanged = event { return true }
        return false
    }

    // MARK: - Повторная попытка

    /// `started` открывает новую попытку: доля прошлой попытки сбрасывается, и первая доля
    /// новой публикуется, хоть и меньше последней опубликованной.
    func test_retryAttemptResetsFraction() async {
        let fixture = FacadeV11Fixture()
        let job = inv35Job(.transcribe(recordingId: UUID(), profileId: "p", language: nil), status: .running)
        fixture.jobQueue.setJobs([job])
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.started(jobId: job.id, type: .transcribe))
        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: 0.8))
        fixture.jobQueue.emit(.failed(jobId: job.id, type: .transcribe, error: "временный", willRetry: true))
        fixture.jobQueue.emit(.started(jobId: job.id, type: .transcribe))
        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: 0.05))
        let events = await collectEvents(stream, count: 5, timeoutSeconds: 1)

        XCTAssertEqual(progressed(events), [0.8, 0.05])
        let status = await fixture.facade.status()
        XCTAssertEqual(status.runningJobs.map(\.fraction), [0.05])
    }

    // MARK: - Завершение задачи

    /// После `succeeded` фасад забывает пару `jobId → type`. Поздний `progressed` по задаче,
    /// которой очередь уже не отдаёт (`job(id:)` — `nil`), не публикуется. Задачу, которую
    /// очередь ещё отдаёт, фасад разрешил бы через `job(id:)` — это вектор «без `started`»
    /// (`JobQueueEventsInv35Tests.test_35e_progressWithoutStartedResolvesTypeOrIsDropped`).
    func test_lateProgressAfterSucceededForJobUnknownToQueueIsDropped() async {
        let fixture = FacadeV11Fixture()
        let jobId = UUID()
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.started(jobId: jobId, type: .transcribe))
        fixture.jobQueue.emit(.progressed(jobId: jobId, fraction: 0.5))
        fixture.jobQueue.emit(.succeeded(jobId: jobId, type: .transcribe))
        fixture.jobQueue.emit(.progressed(jobId: jobId, fraction: 0.9))
        let events = await collectEvents(stream, count: 5, timeoutSeconds: 1)

        XCTAssertEqual(progressed(events), [0.5])
        XCTAssertEqual(events.filter(isStatusChanged).count, 2, "started и succeeded")
    }

    // MARK: - Завершение потока очереди

    /// Критерий MEE-477 «после завершения потока»: события, выданные до `finishEvents()`,
    /// фасад досматривает и публикует; после конца потока `status()` читает очередь и
    /// наблюдённую долю, а другой поток фасада (захват) продолжает публиковать.
    func test_queueStreamFinishedAfterBufferedEventsFacadeKeepsWorking() async throws {
        let fixture = FacadeV11Fixture()
        let job = inv35Job(.transcode(recordingId: UUID()), status: .running)
        fixture.jobQueue.setJobs([job])
        let recordingId = UUID()
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId, enteredAt: Date())])
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.started(jobId: job.id, type: .transcode))
        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: 0.5))
        fixture.jobQueue.finishEvents()
        let buffered = await collectEvents(stream, count: 2, timeoutSeconds: 1)

        XCTAssertEqual(buffered.count, 2, "оба события до конца потока опубликованы: \(buffered)")
        XCTAssertTrue(buffered.first.map(isStatusChanged) ?? false, "started → statusChanged")
        XCTAssertEqual(buffered.last, .jobProgressed(jobId: job.id, type: .transcode, fraction: 0.5))

        let status = await fixture.facade.status()
        XCTAssertEqual(status.runningJobs.map(\.fraction), [0.5])

        fixture.capture.emit(.started(CaptureStarted(recordingId: recordingId, startedAt: Date(),
                                                     tracks: [], captureGroupKey: "zoom")))
        fixture.capture.emit(.capturedProcessesChanged(CapturedProcessSnapshot(
            atMs: 0, observedAt: Date(), requestedAppKey: "zoom", resolvedBundleIds: [], processes: [],
            containsUnrequested: false
        )))
        let afterFinish = await collectEvents(stream, count: 2, timeoutSeconds: 1)
        XCTAssertEqual(afterFinish.count, 1, "поток захвата жив: \(afterFinish)")
        guard case .statusChanged(let published)? = afterFinish.first else { return XCTFail("пришло \(afterFinish)") }
        XCTAssertEqual(published.runningJobs.map(\.jobId), [job.id])
    }

    // MARK: - Порядок failure и statusChanged

    /// Окончательный отказ: `failure` (инв. 31) публикуется раньше `statusChanged` (инв. 35 (е))
    /// того же события.
    func test_failurePrecedesStatusChangedOfSameEvent() async {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.failed(jobId: UUID(), type: .attribute, error: "окончательно", willRetry: false))
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        XCTAssertEqual(events.count, 2)
        guard case .failure(let view)? = events.first else { return XCTFail("первым ожидался failure: \(events)") }
        XCTAssertEqual(view.code, "facade.jobFailed")
        XCTAssertTrue(events.last.map(isStatusChanged) ?? false, "вторым — statusChanged: \(events)")
    }
}
