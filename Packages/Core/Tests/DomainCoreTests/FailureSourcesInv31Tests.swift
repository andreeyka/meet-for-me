//  FailureSourcesInv31Tests — C-016 v11, инв. 31, IR-143 (MEE-457), задача MEE-462:
//  `AppEvent.failure` публикуется по признаку; источники — окончательно упавшая задача и
//  оборванная запись; ручной `syncCalendars()` источником не является.
//
//  «Ровно один `failure` на событие» и «молчит» наблюдаются счётом до барьера: события одного
//  потока фасад обрабатывает по порядку, поэтому лишняя публикация ушла бы раньше ответа на
//  барьер — собирается до трёх событий (предел ожидания 1 с), и число сверяется точно.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class FailureSourcesInv31Tests: XCTestCase {

    // MARK: - Источник (1): JobQueue.events()

    func test_inv31_jobFailedWithoutRetryPublishesOneFacadeJobFailed() async throws {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()
        let jobId = UUID()

        fixture.jobQueue.emit(.failed(jobId: jobId, type: .transcribe, error: "engine.engineFailure.modelMissing",
                                      willRetry: false))
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        XCTAssertEqual(events.count, 1, "ровно один failure на событие-источник")
        guard case .failure(let view)? = events.first else { return XCTFail("ожидался .failure, пришло \(events)") }
        XCTAssertEqual(view.code, "facade.jobFailed")
        XCTAssertNil(view.permissionKind)
        let expected = AppFacadeError.jobFailed(jobId: jobId, type: .transcribe,
                                                message: "engine.engineFailure.modelMissing")
        XCTAssertEqual(view.message, String(describing: expected), "message несёт error дословно")
    }

    /// `willRetry: true` не публикуется; прочие события очереди — тоже. Барьер — окончательный отказ.
    func test_inv31_jobFailedWithRetryAndOtherJobEventsPublishNothing() async throws {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()
        let retried = UUID()
        let final = UUID()

        fixture.jobQueue.emit(.failed(jobId: retried, type: .diarize, error: "временный", willRetry: true))
        fixture.jobQueue.emit(.succeeded(jobId: retried, type: .diarize))
        fixture.jobQueue.emit(.cancelled(jobId: retried, type: .diarize))
        fixture.jobQueue.emit(.failed(jobId: final, type: .attribute, error: "окончательно", willRetry: false))
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        XCTAssertEqual(events.count, 1)
        guard case .failure(let view)? = events.first else { return XCTFail("ожидался .failure, пришло \(events)") }
        XCTAssertTrue(view.message.contains(final.uuidString), "failure — от барьера, не от willRetry: true")
    }

    // MARK: - Источник (2): AudioCapturePort.events()

    func test_inv31_captureFailedPublishesOneCaptureCodeWithPermissionKind() async throws {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()

        fixture.capture.emit(.failed(.systemUnavailable(message: "HAL")))
        fixture.capture.emit(.failed(.microphoneDenied))
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        XCTAssertEqual(events.count, 2, "по одному failure на каждое событие")
        let views = events.compactMap { event -> AppErrorView? in
            if case .failure(let view) = event { return view }
            return nil
        }
        XCTAssertEqual(views.map(\.code), ["capture.systemUnavailable", "capture.microphoneDenied"])
        XCTAssertEqual(views.map(\.permissionKind), [nil, .microphone], "§3.1: тот же wrap, что у синхронного пути")
    }

    // MARK: - Не источник: ручной syncCalendars()

    func test_inv31_syncCalendarsWithFailureResultPublishesNoFailure() async throws {
        let fixture = FacadeV11Fixture()
        let source = CalendarSourceId(rawValue: "graph-work")
        fixture.calendar.setSources([source])
        fixture.calendar.failSync(with: .transport(sourceId: source, message: "сеть"), for: source)
        let stream = fixture.facade.events()

        let results = await fixture.facade.syncCalendars()
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        XCTAssertNotNil(results.first?.failure, "отказ — в синхронном ответе")
        XCTAssertEqual(events.count, 2)
        for event in events {
            if case .failure = event { XCTFail("syncCalendars() не публикует failure: \(event)") }
        }
    }
}
