//  AdHocRecordingsEventsTests — C-016 v12, инвариант 34 (IR-146, MEE-482): `meetingsChanged` в трёх
//  местах — (а) `startRecording(meetingId:)` при любом `meetingId`, до возврата; (б) смена
//  `RecordingStatus` — не позже `statusChanged` для того же изменения; (в) `JobEvent.succeeded` задачи
//  `transcribe`. `transcriptChanged` при появлении нового транскрипта не публикуется.
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

final class AdHocRecordingsEventsTests: XCTestCase {

    private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private func hasTranscriptChanged(_ events: [AppEvent]) -> Bool {
        events.contains { if case .transcriptChanged = $0 { return true } else { return false } }
    }

    // MARK: - (а) startRecording

    /// `meetingsChanged` при любом `meetingId` — и `nil`, и заданном; событие уже в потоке к моменту
    /// возврата и идёт раньше `statusChanged`.
    func test_inv34a_startRecordingPublishesMeetingsChangedBeforeReturn() async throws {
        for meetingId in [nil, UUID()] {
            let fixture = FacadeV11Fixture()
            let stream = fixture.facade.events()

            _ = try await fixture.facade.startRecording(meetingId: meetingId)

            let events = await collectEvents(stream, count: 2, timeoutSeconds: 1)
            XCTAssertEqual(events.first, .meetingsChanged, "meetingId=\(String(describing: meetingId)): \(events)")
            guard case .statusChanged? = events.last, events.count == 2 else {
                return XCTFail("после meetingsChanged ожидался statusChanged, пришло \(events)")
            }
        }
    }

    /// Отказавший старт ничего не менял — и `meetingsChanged` не публикуется.
    func test_inv34a_failedStartPublishesNothing() async throws {
        let fixture = FacadeV11Fixture()
        fixture.coordinator.failStartRecording(with: .nothingToRecord)
        let stream = fixture.facade.events()

        do {
            _ = try await fixture.facade.startRecording(meetingId: nil)
            XCTFail("старт обязан бросить")
        } catch {}

        let events = await collectEvents(stream, count: 1, timeoutSeconds: 1)
        XCTAssertTrue(events.isEmpty, "\(events)")
    }

    // MARK: - (б) смена RecordingStatus

    private func makeFacade(coordinator: ObservedTestSessionCoordinator) -> AppFacadeImpl {
        let repositories = InMemoryRepositories()
        return AppFacadeImpl(
            meetings: repositories.meetings, recordings: repositories.recordings,
            transcripts: repositories.transcripts, persons: repositories.persons,
            speakerProfiles: repositories.speakerProfiles,
            permissions: FakePermissionsPort(startingStatus: .granted, startingOutcome: .granted, checkedAt: epoch),
            modelCatalog: FakeModelCatalogPort(), calendar: FakeCalendarPort(),
            sessionCoordinator: coordinator, attribution: FakeAttributionPort(),
            settings: repositories.settings, connectors: repositories.connectors,
            jobQueue: FakeJobQueue(), fileLayout: FileLayout(root: FileManager.default.temporaryDirectory),
            clock: { [epoch] in epoch }
        )
    }

    private func snapshot(_ sessionId: UUID, state: MeetingStatus, estimate: Double = 1) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: sessionId, origin: .adHoc, meetingId: nil, state: state, recordingId: UUID(),
            target: nil, estimate: estimate, enteredStateAt: epoch, updatedAt: epoch
        )
    }

    /// Смена состояния сессии, с которой `RecordingStatus` записи меняется (`stopping`, дальше
    /// `processing` после `finalized`, `failed`), даёт `meetingsChanged` раньше `statusChanged`.
    func test_inv34b_recordingStatusChangePublishesMeetingsChangedNotLaterThanStatusChanged() async {
        for state in [MeetingStatus.stopping, .processing, .failed] {
            let coordinator = ObservedTestSessionCoordinator()
            let facade = makeFacade(coordinator: coordinator)
            let stream = facade.events()

            coordinator.send(.session(snapshot(UUID(), state: state)))

            let events = await collectEvents(stream, count: 2, timeoutSeconds: 2)
            XCTAssertEqual(events.first, .meetingsChanged, "\(state): \(events)")
            guard case .statusChanged? = events.last, events.count == 2 else {
                return XCTFail("\(state): после meetingsChanged ожидался statusChanged, пришло \(events)")
            }
        }
    }

    /// `stopRecording` сам публикует `statusChanged`; `meetingsChanged` для той же смены — раньше него.
    func test_inv34b_stopRecordingPublishesMeetingsChangedBeforeStatusChanged() async throws {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()

        try await fixture.facade.stopRecording(recordingId: UUID())

        let events = await collectEvents(stream, count: 2, timeoutSeconds: 1)
        XCTAssertEqual(events.first, .meetingsChanged, "\(events)")
        guard case .statusChanged? = events.last, events.count == 2 else {
            return XCTFail("после meetingsChanged ожидался statusChanged, пришло \(events)")
        }
    }

    // MARK: - (в) JobEvent.succeeded задачи transcribe

    /// `meetingsChanged` ровно один раз и раньше `statusChanged` того же события (инв. 34 (б), 35 (е));
    /// `transcriptChanged` нет. `statusChanged` от наблюдения очереди разрешён.
    func test_inv34c_transcribeSucceededPublishesMeetingsChangedAndNoTranscriptChanged() async {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()

        fixture.jobQueue.emit(.succeeded(jobId: UUID(), type: .transcribe))

        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)
        let meetingsChangedIndices = events.indices.filter { events[$0] == .meetingsChanged }
        XCTAssertEqual(meetingsChangedIndices.count, 1, "meetingsChanged ровно один раз: \(events)")
        XCTAssertFalse(hasTranscriptChanged(events), "новый транскрипт `transcriptChanged` не публикует")
        let statusChangedIndex = events.firstIndex { if case .statusChanged = $0 { return true } else { return false } }
        if let meetings = meetingsChangedIndices.first, let status = statusChangedIndex {
            XCTAssertLessThan(meetings, status, "meetingsChanged раньше statusChanged: \(events)")
        }
    }

    /// Прочие события очереди не источник: `succeeded` другой задачи, `started`, `cancelled` и
    /// `failed(willRetry: true)` `transcribe` `meetingsChanged` не дают. Барьер — настоящее `succeeded`
    /// `transcribe` в конце: его `statusChanged` пятый (каждое из пяти событий даёт по одному, инв. 35 (е)),
    /// до него считаются только `meetingsChanged`.
    func test_inv34c_otherJobEventsDoNotPublishMeetingsChanged() async {
        let fixture = FacadeV11Fixture()
        let stream = fixture.facade.events()
        let jobId = UUID()

        fixture.jobQueue.emit(.succeeded(jobId: jobId, type: .diarize))
        fixture.jobQueue.emit(.started(jobId: jobId, type: .transcribe))
        fixture.jobQueue.emit(.cancelled(jobId: jobId, type: .transcribe))
        fixture.jobQueue.emit(.failed(jobId: jobId, type: .transcribe, error: "временный", willRetry: true))
        fixture.jobQueue.emit(.succeeded(jobId: jobId, type: .transcribe))

        let events = await collectMeetingsChanged(stream, untilStatusChanges: 5, timeoutSeconds: 1)
        XCTAssertEqual(events, [.meetingsChanged], "ровно одно — на барьере")
    }
}

/// Только `.meetingsChanged` — до барьера: `untilStatusChanges`-го `statusChanged` (по образцу
/// `collectStatusChanges` в `SessionObservationTests.swift`, с обратным фильтром).
private func collectMeetingsChanged(
    _ stream: AsyncStream<AppEvent>, untilStatusChanges barrier: Int, timeoutSeconds: UInt64 = 5
) async -> [AppEvent] {
    let iterator = stream.makeAsyncIterator()
    var collected: [AppEvent] = []
    var statusChanges = 0
    while statusChanges < barrier {
        guard let event = await nextEventOrNil(iterator, seconds: timeoutSeconds) else { break }
        switch event {
        case .meetingsChanged: collected.append(event)
        case .statusChanged: statusChanges += 1
        default: continue
        }
    }
    return collected
}
