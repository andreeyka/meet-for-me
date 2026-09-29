//  JobQueueEventsInv35Tests — C-016 v13, инв. 35 (д), (е) (IR-147, MEE-476; задача MEE-477):
//  `jobProgressed` по `JobEvent.progressed`, `statusChanged` по событиям, меняющим состав
//  очереди. Векторы (35д), (35е) абзаца «Ломающие изменения против v12». Жизненный цикл
//  задачи и потока очереди — `JobQueueLifecycleInv35Tests.swift`.
//
//  «Не публикуется» наблюдается счётом до барьера — тем же приёмом, что
//  `FailureSourcesInv31Tests`: события одного потока фасад обрабатывает по порядку, поэтому
//  лишняя публикация пришла бы раньше барьера; собирается с запасом, число сверяется точно.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class JobQueueEventsInv35Tests: XCTestCase {

    private func progressed(_ events: [AppEvent]) -> [Double] {
        events.compactMap { event in
            if case let .jobProgressed(_, _, fraction) = event { return fraction }
            return nil
        }
    }

    private func statusChangedCount(_ events: [AppEvent]) -> Int {
        events.filter { event in
            if case .statusChanged = event { return true }
            return false
        }.count
    }

    // MARK: - (35д) jobProgressed

    /// 0.10, 0.105, 0.11, 0.30 — публикуются 0.10, 0.11, 0.30; `type` — из `started`.
    func test_35e_progressStepOfOneHundredth() async {
        let fixture = FacadeV11Fixture()
        let jobId = UUID()
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.started(jobId: jobId, type: .transcribe))
        for fraction in [0.10, 0.105, 0.11, 0.30] {
            fixture.jobQueue.emit(.progressed(jobId: jobId, fraction: fraction))
        }
        let events = await collectEvents(stream, count: 6, timeoutSeconds: 1)

        XCTAssertEqual(progressed(events), [0.10, 0.11, 0.30])
        let types = events.compactMap { event -> JobType? in
            if case let .jobProgressed(id, type, _) = event, id == jobId { return type }
            return nil
        }
        XCTAssertEqual(types, [.transcribe, .transcribe, .transcribe])
    }

    /// `fraction` приводится к `0...1`; не число — отбрасывается.
    func test_35e_fractionClampedAndNaNDropped() async {
        let fixture = FacadeV11Fixture()
        let jobId = UUID()
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.started(jobId: jobId, type: .transcode))
        fixture.jobQueue.emit(.progressed(jobId: jobId, fraction: -0.5))
        fixture.jobQueue.emit(.progressed(jobId: jobId, fraction: .nan))
        fixture.jobQueue.emit(.progressed(jobId: jobId, fraction: 1.5))
        let events = await collectEvents(stream, count: 5, timeoutSeconds: 1)

        XCTAssertEqual(progressed(events), [0, 1.0])
    }

    /// Без `started`: задача есть в очереди — `type` из `job(id:)`; задачи нет — не публикуется.
    func test_35e_progressWithoutStartedResolvesTypeOrIsDropped() async {
        let fixture = FacadeV11Fixture()
        let known = inv35Job(.diarize(recordingId: UUID(), profileId: "p"), status: .running)
        fixture.jobQueue.setJobs([known])
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.progressed(jobId: UUID(), fraction: 0.5))
        fixture.jobQueue.emit(.progressed(jobId: known.id, fraction: 0.2))
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        XCTAssertEqual(events, [.jobProgressed(jobId: known.id, type: .diarize, fraction: 0.2)])
    }

    /// MEE-488, п. 1: поздний `progressed` после `succeeded` — пара забыта, `job(id:)` вернёт
    /// завершённую задачу; она не идёт, поэтому доля не публикуется. Барьер — `cancelled`.
    func test_35e_lateProgressAfterSucceededIsDropped() async {
        let fixture = FacadeV11Fixture()
        let job = inv35Job(.transcode(recordingId: UUID()), status: .succeeded)
        fixture.jobQueue.setJobs([job])
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.started(jobId: job.id, type: .transcode))
        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: 0.2))
        fixture.jobQueue.emit(.succeeded(jobId: job.id, type: .transcode))
        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: 0.9))
        fixture.jobQueue.emit(.cancelled(jobId: UUID(), type: .transcode))
        let events = await collectEvents(stream, count: 6, timeoutSeconds: 1)

        XCTAssertEqual(progressed(events), [0.2])
        XCTAssertEqual(statusChangedCount(events), 3, "started, succeeded и барьер")
        XCTAssertEqual(events.count, 4)
    }

    /// MEE-488, п. 1: без пары `job(id:)` принимается только в `running`; задача в любом
    /// другом статусе — не публикуется. Барьер — `cancelled`.
    func test_35e_progressWithoutStartedAcceptsOnlyRunningJob() async {
        let fixture = FacadeV11Fixture()
        let statuses: [JobStatus] = [.pending, .succeeded, .failed, .cancelled]
        let jobs = statuses.map { inv35Job(.transcode(recordingId: UUID()), status: $0) }
        fixture.jobQueue.setJobs(jobs)
        let stream = fixture.facade.events()

        for job in jobs {
            fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: 0.5))
        }
        fixture.jobQueue.emit(.cancelled(jobId: UUID(), type: .transcode))
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        XCTAssertEqual(progressed(events), [])
        XCTAssertEqual(events.count, 1, "только барьер")
        XCTAssertEqual(fixture.jobQueue.callLog.count(port: FakeJobQueue.portName, method: "job(id:)"), jobs.count)
    }

    /// MEE-488, п. 5: `NaN` первым событием задачи после `started` не публикуется и не
    /// становится наблюдённой долей: `runningJobs` барьера несёт `0`, а следующее число —
    /// первое опубликованное.
    func test_35e_nanAsFirstProgressIsDroppedWithoutTouchingFraction() async {
        let fixture = FacadeV11Fixture()
        let job = inv35Job(.transcode(recordingId: UUID()), status: .running)
        fixture.jobQueue.setJobs([job])
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.started(jobId: job.id, type: .transcode))
        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: .nan))
        fixture.jobQueue.emit(.submitted(jobId: UUID(), type: .transcode))
        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: 0.004))
        let events = await collectEvents(stream, count: 4, timeoutSeconds: 1)

        XCTAssertEqual(events.count, 3)
        guard events.count == 3, case .statusChanged(let barrier) = events[1] else {
            return XCTFail("пришло \(events)")
        }
        XCTAssertEqual(barrier.runningJobs.map(\.fraction), [0])
        XCTAssertEqual(events[2], .jobProgressed(jobId: job.id, type: .transcode, fraction: 0.004))
    }

    /// MEE-488, п. 5: `NaN` первым событием задачи без `started` отбрасывается до `job(id:)` —
    /// в очередь не ходит и не публикуется. Барьер — `cancelled`.
    func test_35e_nanWithoutStartedSkipsJobLookup() async {
        let fixture = FacadeV11Fixture()
        let job = inv35Job(.transcode(recordingId: UUID()), status: .running)
        fixture.jobQueue.setJobs([job])
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.progressed(jobId: job.id, fraction: .nan))
        fixture.jobQueue.emit(.cancelled(jobId: UUID(), type: .transcode))
        let events = await collectEvents(stream, count: 2, timeoutSeconds: 1)

        XCTAssertEqual(events.count, 1, "только барьер")
        XCTAssertEqual(fixture.jobQueue.callLog.count(port: FakeJobQueue.portName, method: "job(id:)"), 0)
    }

    // MARK: - (35е) statusChanged

    /// `submitted`, `started`, `succeeded`, `failed`, `cancelled` — по одному `statusChanged`.
    func test_35f_eachQueueChangingEventPublishesOneStatusChanged() async {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()
        let events: [JobEvent] = [
            .submitted(jobId: UUID(), type: .transcode),
            .started(jobId: UUID(), type: .transcode),
            .succeeded(jobId: UUID(), type: .transcode),
            .failed(jobId: UUID(), type: .transcode, error: "e", willRetry: true),
            .failed(jobId: UUID(), type: .transcode, error: "e", willRetry: false),
            .cancelled(jobId: UUID(), type: .transcode)
        ]
        for event in events {
            fixture.jobQueue.emit(event)
        }
        let published = await collectEvents(stream, count: 9, timeoutSeconds: 1)

        XCTAssertEqual(statusChangedCount(published), 6)
        XCTAssertEqual(published.count, 7, "плюс один failure инв. 31 на окончательный отказ")
    }

    /// `progressed` и `blocked` — ни одного `statusChanged`. Барьер — `cancelled`.
    func test_35f_progressedAndBlockedPublishNoStatusChanged() async {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()
        let jobId = UUID()
        fixture.jobQueue.setJobs([inv35Job(.transcode(recordingId: UUID()), status: .running, id: jobId)])

        fixture.jobQueue.emit(.progressed(jobId: jobId, fraction: 0.1))
        fixture.jobQueue.emit(.progressed(jobId: jobId, fraction: 0.5))
        fixture.jobQueue.emit(.blocked(jobId: jobId, type: .transcode, reason: .waitingForACPower))
        fixture.jobQueue.emit(.cancelled(jobId: UUID(), type: .transcode))
        let published = await collectEvents(stream, count: 5, timeoutSeconds: 1)

        XCTAssertEqual(progressed(published), [0.1, 0.5])
        XCTAssertEqual(statusChangedCount(published), 1, "только барьер")
        XCTAssertEqual(published.count, 3)
    }

    /// `statusChanged` на `started` несёт идущую задачу с долей 0 (новая попытка).
    func test_35f_statusOnStartedCarriesRunningJob() async {
        let fixture = FacadeV11Fixture()
        let job = inv35Job(.transcode(recordingId: UUID()), status: .running)
        fixture.jobQueue.setJobs([job])
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.started(jobId: job.id, type: .transcode))
        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)

        guard case .statusChanged(let status)? = events.first else { return XCTFail("пришло \(events)") }
        XCTAssertEqual(status.runningJobs.map(\.jobId), [job.id])
        XCTAssertEqual(status.runningJobs.map(\.fraction), [0])
    }
}
