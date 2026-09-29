//  AdHocRecordingsEventsTests — гонки команд записи со снимками сессии (MEE-494, пункты Б1–Б4 из
//  повторного ревью #213): поздний ответ `startRecording`/`stopRecording` после снимка
//  `processing` или терминального не даёт `meetingsChanged` и не оставляет записей в кэшах;
//  `skipMeeting` из записи и обработки (машина ничего не делает) — без `meetingsChanged`; пара
//  «команда старта и снимок `.recording`» — одно событие в обоих порядках; Stop встречи, связь с
//  которой пришла только из команды. Разведено из тела класса по объёму (`type_body_length`).
//
//  Модуль: domain-core · Владелец: DEV-1 · Слой: домен

import XCTest
import DomainCore
import DomainTestKit

extension AdHocRecordingsEventsTests {

    func meetingRecord(_ meetingId: UUID, status: MeetingStatus) throws -> MeetingRecord {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let event = try MeetingEvent(
            id: meetingId, sourceConnectorId: "eventkit", externalId: "evt-\(meetingId.uuidString.prefix(8))",
            icalUid: nil, title: "Созвон", start: start, end: start.addingTimeInterval(1_800),
            timeZone: "UTC", isAllDay: false, isCancelled: false, organizer: nil, attendees: [], location: nil,
            bodyText: nil, conference: nil, lastModified: start
        )
        return MeetingRecord(event: event, dedupKey: nil, status: status, sources: [])
    }

    // MARK: - Б4: старт встречи — команда и снимок `.recording`

    /// `startRecording(meetingId:)` и снимок `.recording` той же записи — одно `meetingsChanged` в
    /// обоих порядках, и оно первое.
    func test_lateCommands_startRecordingAndRecordingSnapshotPublishMeetingsChangedOnce() async throws {
        for snapshotFirst in [false, true] {
            let coordinator = ObservedTestSessionCoordinator()
            let facade = makeFacade(coordinator: coordinator)
            let stream = facade.events()
            let meetingId = UUID()
            let recordingId = UUID()
            coordinator.setStartRecordingId(recordingId)
            let recording = snapshot(
                UUID(), state: .recording, recordingId: recordingId, origin: .scheduled, meetingId: meetingId
            )
            var events: [AppEvent] = []

            if snapshotFirst {
                coordinator.send(.session(recording))
                events += await collectEvents(stream, count: 2, timeoutSeconds: 1)
                _ = try await facade.startRecording(meetingId: meetingId)
            } else {
                _ = try await facade.startRecording(meetingId: meetingId)
                coordinator.send(.session(recording))
            }
            events += await collectEvents(stream, count: 4 - events.count, timeoutSeconds: 1)

            XCTAssertEqual(meetingsChangedCount(events), 1, "snapshotFirst=\(snapshotFirst): \(events)")
            XCTAssertEqual(events.first, .meetingsChanged, "snapshotFirst=\(snapshotFirst): \(events)")
            XCTAssertEqual(statusChangedCount(events), 2, "snapshotFirst=\(snapshotFirst): \(events)")
        }
    }

    // MARK: - Б4: Stop встречи, связь только из команды

    /// Встречу записи фасад узнал только из ответа `startRecording(meetingId:)` — снимков ещё не было.
    /// `stopRecording` публикует `meetingsChanged` со статусом встречи `stopping`: поздний снимок
    /// `stopping` той же встречи второго события не даёт (без связи статус встречи остался бы
    /// `recording`, и снимок дал бы второе).
    func test_lateCommands_stopMeetingKnownOnlyFromCommand() async throws {
        let coordinator = ObservedTestSessionCoordinator()
        let facade = makeFacade(coordinator: coordinator)
        let stream = facade.events()
        let meetingId = UUID()
        let recordingId = UUID()
        coordinator.setStartRecordingId(recordingId)
        _ = try await facade.startRecording(meetingId: meetingId)
        _ = await collectEvents(stream, count: 2, timeoutSeconds: 1)

        try await facade.stopRecording(recordingId: recordingId)
        var events = await collectEvents(stream, count: 2, timeoutSeconds: 1)
        coordinator.send(.session(snapshot(
            UUID(), state: .stopping, recordingId: recordingId, origin: .scheduled, meetingId: meetingId
        )))
        events += await collectEvents(stream, count: 2, timeoutSeconds: 1)

        XCTAssertEqual(events.first, .meetingsChanged, "\(events)")
        XCTAssertEqual(meetingsChangedCount(events), 1, "\(events)")
        XCTAssertEqual(statusChangedCount(events), 2, "\(events)")
    }

    // MARK: - Б1: поздний ответ `startRecording`

    /// Снимок `processing` или терминальный пришёл раньше ответа `startRecording` — ответ даёт
    /// только `statusChanged`. Кэши не пополнены: следующий `stopRecording` той же записи тоже без
    /// `meetingsChanged` (с утёкшей связью «запись — встреча» он опубликовал бы `stopping`).
    func test_lateCommands_startRecordingAfterLaterSnapshotPublishesNoMeetingsChanged() async throws {
        for lateState in [MeetingStatus.processing, .ready, .failed] {
            let coordinator = ObservedTestSessionCoordinator()
            let facade = makeFacade(coordinator: coordinator)
            let stream = facade.events()
            let meetingId = UUID()
            let recordingId = UUID()
            coordinator.setStartRecordingId(recordingId)
            coordinator.send(.session(snapshot(
                UUID(), state: lateState, recordingId: recordingId, origin: .scheduled, meetingId: meetingId
            )))
            _ = await collectEvents(stream, count: 2, timeoutSeconds: 1)

            _ = try await facade.startRecording(meetingId: meetingId)
            try await facade.stopRecording(recordingId: recordingId)
            let events = await collectEvents(stream, count: 3, timeoutSeconds: 1)

            XCTAssertEqual(meetingsChangedCount(events), 0, "\(lateState): \(events)")
            XCTAssertEqual(statusChangedCount(events), 2, "\(lateState): \(events)")
        }
    }

    // MARK: - Б2: поздний ответ `stopRecording`

    /// Снимок `processing` или терминальный пришёл раньше ответа `stopRecording` — ответ не
    /// откатывает строку встречи в `stopping` и `meetingsChanged` не даёт.
    func test_lateCommands_stopRecordingAfterLaterSnapshotPublishesNoMeetingsChanged() async throws {
        for lateState in [MeetingStatus.processing, .ready, .failed] {
            let coordinator = ObservedTestSessionCoordinator()
            let facade = makeFacade(coordinator: coordinator)
            let stream = facade.events()
            let meetingId = UUID()
            let recordingId = UUID()
            coordinator.setStartRecordingId(recordingId)
            _ = try await facade.startRecording(meetingId: meetingId)
            coordinator.send(.session(snapshot(
                UUID(), state: lateState, recordingId: recordingId, origin: .scheduled, meetingId: meetingId
            )))
            _ = await collectEvents(stream, count: 4, timeoutSeconds: 1)

            try await facade.stopRecording(recordingId: recordingId)
            let events = await collectEvents(stream, count: 2, timeoutSeconds: 1)

            XCTAssertEqual(meetingsChangedCount(events), 0, "\(lateState): \(events)")
            XCTAssertEqual(statusChangedCount(events), 1, "\(lateState): \(events)")
        }
    }

    // MARK: - Б3: `skipMeeting` из записи и обработки

    /// Из `recording`/`stopping`/`processing` машина `skip` не меняет ничего — встреча в хранилище
    /// остаётся в прежнем статусе, и `meetingsChanged` нет; `statusChanged` (инв. 15) — есть.
    func test_lateCommands_skipMeetingWhileRecordingPublishesNoMeetingsChanged() async throws {
        for state in [MeetingStatus.recording, .stopping, .processing] {
            let coordinator = ObservedTestSessionCoordinator()
            let repositories = InMemoryRepositories()
            let facade = makeFacade(coordinator: coordinator, repositories: repositories)
            let stream = facade.events()
            let meetingId = UUID()
            try await repositories.meetings.save(meetingRecord(meetingId, status: state))

            try await facade.skipMeeting(meetingId: meetingId)
            let events = await collectEvents(stream, count: 2, timeoutSeconds: 1)

            XCTAssertEqual(meetingsChangedCount(events), 0, "\(state): \(events)")
            XCTAssertEqual(statusChangedCount(events), 1, "\(state): \(events)")
        }
    }
}
