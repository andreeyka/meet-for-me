//  FailureSourcesInv31Tests — C-016 v11, инв. 31, IR-143 (MEE-457), задача MEE-462:
//  `AppEvent.failure` публикуется по признаку; источники — окончательно упавшая задача и
//  оборванная запись; ручной `syncCalendars()` источником не является. Критерии К60, К61
//  дельты `АВ` перечня MEE-401 (`f89d2865`).
//
//  «Ровно один `failure` на событие» и «молчит» наблюдаются счётом до барьера: события одного
//  потока фасад обрабатывает по порядку, поэтому лишняя публикация ушла бы раньше ответа на
//  барьер — собирается до трёх событий (предел ожидания 1 с), и число сверяется точно.
//
//  Модуль: domain-core · Владелец: DEV-2 · Слой: домен

import XCTest
@testable import DomainCore
import DomainTestKit

final class FailureSourcesInv31Tests: XCTestCase {

    // MARK: - Источник (1): JobQueue.events()

    func test_k60i_jobFailedWithoutRetryPublishesOneFacadeJobFailed() async throws {
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
    }

    /// Инв. 31: `message` случая `jobFailed` — текст `error` события дословно. С границы
    /// `AppErrorView.message` не сравнивается (§3.1, «Что стабильно»), поэтому проверяется
    /// значение `AppFacadeError` до свода к `AppErrorView`.
    func test_k60i_jobFailedValueCarriesEventErrorVerbatim() {
        let jobId = UUID()
        let event = JobEvent.failed(jobId: jobId, type: .transcribe, error: "boom: движок", willRetry: false)
        XCTAssertEqual(AppFacadeImpl.jobFailedError(for: event),
                       .jobFailed(jobId: jobId, type: .transcribe, message: "boom: движок"))
        let retried = JobEvent.failed(jobId: jobId, type: .transcribe, error: "boom", willRetry: true)
        XCTAssertNil(AppFacadeImpl.jobFailedError(for: retried), "willRetry: true — не источник")
    }

    /// `willRetry: true` не публикуется; прочие события очереди — тоже. Барьер — окончательный отказ.
    func test_k60ii_jobFailedWithRetryAndOtherJobEventsPublishNothing() async throws {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()
        let retried = UUID()
        let final = UUID()

        fixture.jobQueue.emit(.failed(jobId: retried, type: .diarize, error: "временный", willRetry: true))
        fixture.jobQueue.emit(.succeeded(jobId: retried, type: .diarize))
        fixture.jobQueue.emit(.cancelled(jobId: retried, type: .diarize))
        fixture.jobQueue.emit(.failed(jobId: final, type: .attribute, error: "окончательно", willRetry: false))
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        XCTAssertEqual(events.count, 1, "willRetry: true и прочие события — ни одного failure; один — от барьера")
        guard case .failure(let view)? = events.first else { return XCTFail("ожидался .failure, пришло \(events)") }
        XCTAssertEqual(view.code, "facade.jobFailed")
    }

    // MARK: - Источник (2): AudioCapturePort.events()

    func test_k60iii_captureFailedPublishesOneCaptureCodeWithPermissionKind() async throws {
        let fixture = FacadeV11Fixture()
        // Вход К60 (iii) — «при идущей записи»: сессия в `recording`, захват сообщил о старте.
        let recordingId = UUID()
        fixture.coordinator.setSessions([recordingSession(recordingId: recordingId, enteredAt: Date())])
        let stream = fixture.facade.events()

        fixture.capture.emit(.started(CaptureStarted(recordingId: recordingId, startedAt: Date(),
                                                     tracks: [], captureGroupKey: "zoom")))
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

    func test_k61_syncCalendarsWithFailureResultPublishesNoFailure() async throws {
        let fixture = FacadeV11Fixture()
        let source = CalendarSourceId(rawValue: "graph-work")
        fixture.calendar.setSources([source])
        fixture.calendar.failSync(with: .transport(sourceId: source, message: "сеть"), for: source)
        let stream = fixture.facade.events()

        let results = await fixture.facade.syncCalendars()
        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

        XCTAssertNotNil(results.first?.failure, "отказ — в синхронном ответе")
        for event in events {
            if case .failure = event { XCTFail("syncCalendars() не публикует failure: \(event)") }
        }
    }
}
