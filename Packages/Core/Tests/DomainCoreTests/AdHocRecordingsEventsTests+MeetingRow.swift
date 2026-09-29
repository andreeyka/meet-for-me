//  AdHocRecordingsEventsTests — строка встречи (MEE-492, решение РП по ревью #213, вариант (а)):
//  `meetingsChanged` и на смене `MeetingStatus` встречи снимка, а не только `RecordingStatus`, —
//  иначе строка встречи в окне залипает в старом статусе. Команда и снимок об одном изменении
//  дают одно событие. Разведено из тела класса по объёму (`type_body_length`).
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension AdHocRecordingsEventsTests {

    /// Каждая смена статуса встречи — `meetingsChanged` раньше своего `statusChanged`, в том числе
    /// там, где статус записи не меняется: `scheduled → armed → awaitingSignal` (записи нет),
    /// `processing → ready` (запись уже `finalized`).
    func test_meetingRow_everyMeetingStatusChangePublishesMeetingsChanged() async {
        let coordinator = ObservedTestSessionCoordinator()
        let facade = makeFacade(coordinator: coordinator)
        let stream = facade.events()
        let sessionId = UUID()
        let meetingId = UUID()
        let recordingId = UUID()
        let states: [(MeetingStatus, UUID?)] = [
            (.scheduled, nil), (.armed, nil), (.awaitingSignal, nil),
            (.recording, recordingId), (.stopping, recordingId), (.processing, recordingId), (.ready, recordingId)
        ]

        for (state, recording) in states {
            coordinator.send(.session(snapshot(
                sessionId, state: state, recordingId: recording, origin: .scheduled, meetingId: meetingId
            )))
        }

        let events = await collectEvents(stream, count: 15, timeoutSeconds: 1)
        XCTAssertEqual(events.count, 14, "\(events)")
        for index in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[index], .meetingsChanged, "смена №\(index / 2 + 1): \(events)")
        }
        XCTAssertEqual(statusChangedCount(events), 7, "\(events)")
    }

    /// Повтор того же снимка (то же состояние, новая оценка) — ни `meetingsChanged`, ни `statusChanged`.
    func test_meetingRow_repeatedSnapshotPublishesNothing() async {
        let coordinator = ObservedTestSessionCoordinator()
        let facade = makeFacade(coordinator: coordinator)
        let stream = facade.events()
        let sessionId = UUID()
        let meetingId = UUID()

        for estimate in [0.2, 0.5] {
            coordinator.send(.session(snapshot(
                sessionId, state: .armed, recordingId: nil, origin: .scheduled, meetingId: meetingId, estimate: estimate
            )))
        }

        let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)
        XCTAssertEqual(meetingsChangedCount(events), 1, "\(events)")
        XCTAssertEqual(events.count, 2, "повтор снимка молчит: \(events)")
    }

    /// `failed` без записи (встречу не удалось записать) и `processing → failed` при равном ранге
    /// статуса записи — строка встречи меняется, событие есть.
    func test_meetingRow_failedWithoutRecordingAndAfterProcessingPublishMeetingsChanged() async {
        let coordinator = ObservedTestSessionCoordinator()
        let facade = makeFacade(coordinator: coordinator)
        let stream = facade.events()
        let first = UUID()
        let second = UUID()
        let recordingId = UUID()
        let secondSession = UUID()

        coordinator.send(.session(snapshot(
            UUID(), state: .failed, recordingId: nil, origin: .scheduled, meetingId: first
        )))
        for state in [MeetingStatus.processing, .failed] {
            coordinator.send(.session(snapshot(
                secondSession, state: state, recordingId: recordingId, origin: .scheduled, meetingId: second
            )))
        }

        let events = await collectEvents(stream, count: 7, timeoutSeconds: 1)
        XCTAssertEqual(meetingsChangedCount(events), 3, "\(events)")
        XCTAssertEqual(statusChangedCount(events), 3, "\(events)")
    }

    /// Stop встречи: команда и снимок `stopping` — одно `meetingsChanged` в обоих порядках. Встречу
    /// записи фасад узнал из снимка `.recording` (автостарт).
    func test_meetingRow_stopRecordingAndSnapshotPublishMeetingsChangedOnce() async throws {
        for snapshotFirst in [false, true] {
            let coordinator = ObservedTestSessionCoordinator()
            let facade = makeFacade(coordinator: coordinator)
            let stream = facade.events()
            let sessionId = UUID()
            let meetingId = UUID()
            let recordingId = UUID()
            coordinator.send(.session(snapshot(
                sessionId, state: .recording, recordingId: recordingId, origin: .scheduled, meetingId: meetingId
            )))
            _ = await collectEvents(stream, count: 2, timeoutSeconds: 1)
            let stopping = snapshot(
                sessionId, state: .stopping, recordingId: recordingId, origin: .scheduled, meetingId: meetingId
            )
            var events: [AppEvent] = []

            if snapshotFirst {
                coordinator.send(.session(stopping))
                events += await collectEvents(stream, count: 2, timeoutSeconds: 1)
                try await facade.stopRecording(recordingId: recordingId)
            } else {
                try await facade.stopRecording(recordingId: recordingId)
                coordinator.send(.session(stopping))
            }
            events += await collectEvents(stream, count: 4 - events.count, timeoutSeconds: 1)

            XCTAssertEqual(meetingsChangedCount(events), 1, "snapshotFirst=\(snapshotFirst): \(events)")
            XCTAssertEqual(events.first, .meetingsChanged, "snapshotFirst=\(snapshotFirst): \(events)")
            XCTAssertEqual(statusChangedCount(events), 2, "snapshotFirst=\(snapshotFirst): \(events)")
        }
    }

    /// Пропуск: команда `skipMeeting` и снимок `skipped` — одно `meetingsChanged` в обоих порядках.
    /// Встреча в хранилище уже `skipped`: машина пишет статус раньше возврата (C-018 инв. 18).
    func test_meetingRow_skipMeetingAndSnapshotPublishMeetingsChangedOnce() async throws {
        for snapshotFirst in [false, true] {
            let coordinator = ObservedTestSessionCoordinator()
            let repositories = InMemoryRepositories()
            let facade = makeFacade(coordinator: coordinator, repositories: repositories)
            let stream = facade.events()
            let meetingId = UUID()
            try await repositories.meetings.save(meetingRecord(meetingId, status: .skipped))
            let skipped = snapshot(UUID(), state: .skipped, recordingId: nil, origin: .scheduled, meetingId: meetingId)
            var events: [AppEvent] = []

            if snapshotFirst {
                coordinator.send(.session(skipped))
                events += await collectEvents(stream, count: 2, timeoutSeconds: 1)
                try await facade.skipMeeting(meetingId: meetingId)
            } else {
                try await facade.skipMeeting(meetingId: meetingId)
                coordinator.send(.session(skipped))
            }
            events += await collectEvents(stream, count: 4 - events.count, timeoutSeconds: 1)

            XCTAssertEqual(meetingsChangedCount(events), 1, "snapshotFirst=\(snapshotFirst): \(events)")
            XCTAssertEqual(events.first, .meetingsChanged, "snapshotFirst=\(snapshotFirst): \(events)")
        }
    }
}
