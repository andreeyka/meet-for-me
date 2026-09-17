//  MEE-290: `DomainTestKit.FakeSessionCoordinator` — §«Фейк для тестов» C-018 и критерий К87
//  плана MEE-288.
//
//  К87 подаётся здесь целиком, четырьмя гранями, и все четыре взяты у критерия дословно:
//  задаются наборы `SessionSnapshot` и `SessionPrompt`; ЛЮБОЙ `SessionChange` проталкивается
//  в `changes()`; ЛЮБАЯ команда заставляется бросить ЛЮБУЮ `SessionError`; все вызванные
//  команды с аргументами записываются и отдаются тесту списком.
//
//  ПЯТАЯ ГРАНЬ — ТА, РАДИ КОТОРОЙ ФЕЙК И СУЩЕСТВУЕТ, и она стоит отдельным вектором: фейк
//  ВПРАВЕ отдать снимок, которого верная машина не отдаст, — `recordingId == nil` в состоянии
//  `recording`. Различающий вектор К87 назван критерием прямо: фейк, приводящий снимок к
//  инвариантам машины, красен на этом входе, и цена его в том, что проверка снимается у
//  ЧУЖОГО модуля — у фасада C-016.
//
//  ГРАНИЦА НАЗВАНА: ни одно утверждение этого файла не говорит о поведении МАШИНЫ. Машины
//  в дереве нет ни строкой, и `SessionCoordinator` здесь — только объявление.

import XCTest
import DomainCore
import DomainTestKit

final class FakeSessionCoordinatorTests: XCTestCase {

    private let sessionId = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000001")
    private let meetingId = MeetingEventFixtures.oneOnOneZoom.id

    // MARK: - (а) снимок, которого верная машина не отдаст, проходит НЕИЗМЕНЁННЫМ

    func test_k87_fakeSessionCoordinator_passesSnapshotAValidMachineWouldNotEmit() async throws {
        let coordinator = FakeSessionCoordinator()
        let identifier = try XCTUnwrap(sessionId)
        // `recordingId == nil` в состоянии `recording` — пример из контракта дословно.
        let broken = SessionSnapshot(
            sessionId: identifier,
            origin: .adHoc,
            meetingId: meetingId,          // и это тоже негодно: `nil ⟺ origin == .adHoc`
            state: .recording,
            recordingId: nil,
            target: nil,
            estimate: 42,                  // за пределами `0...1`
            enteredStateAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        coordinator.setSessions([broken])

        let answer = await coordinator.sessions()
        XCTAssertEqual(answer.count, 1, "вектор непустоты: снимок дошёл, а не был отфильтрован")
        XCTAssertEqual(answer.first, broken, "значение равно заданному до поля")
        XCTAssertNil(answer.first?.recordingId, "recordingId не подставлен")
        XCTAssertEqual(answer.first?.estimate, 42, "estimate не зажат в 0...1")
        XCTAssertEqual(answer.first?.meetingId, meetingId, "meetingId не приведён к origin")
        let byId = await coordinator.session(id: identifier)
        XCTAssertEqual(byId, broken)
    }

    /// Терминальные снимки фейк не отсеивает и по `sessionId` не сортирует: обе клаузы
    /// контракта — обязанность машины.
    func test_k87_fakeSessionCoordinator_doesNotFilterTerminalNorSort() async {
        let coordinator = FakeSessionCoordinator()
        let high = snapshot(id: UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000001"), state: .ready)
        let low = snapshot(id: UUID(uuidString: "11111111-0000-4000-8000-000000000001"), state: .armed)
        coordinator.setSessions([high, low])

        let answer = await coordinator.sessions()
        XCTAssertEqual(answer.count, 2, "вектор непустоты: терминальная не отсеяна")
        XCTAssertEqual(answer.map(\.sessionId), [high.sessionId, low.sessionId], "порядок задания сохранён")
        XCTAssertTrue(answer.contains { $0.state == .ready }, "терминальное состояние дошло")
    }

    // MARK: - (б) набор спросов задаётся и отдаётся как есть

    func test_k87_fakeSessionCoordinator_promptsAreGivenByTest() async throws {
        let coordinator = FakeSessionCoordinator()
        let identifier = try XCTUnwrap(sessionId)
        let second = UUID(uuidString: "AAAAAAAA-0000-4000-8000-000000000002")
        let candidates = [try XCTUnwrap(second), identifier]   // намеренно НЕ по возрастанию
        let prompts = [
            SessionPrompt(
                promptId: UUID(), sessionId: identifier, kind: .recordThisMeeting,
                raisedAt: Date(timeIntervalSince1970: 0), expiresAt: nil
            ),
            SessionPrompt(
                promptId: UUID(), sessionId: identifier, kind: .whichMeeting(candidates: candidates),
                raisedAt: Date(timeIntervalSince1970: 0), expiresAt: Date(timeIntervalSince1970: 30)
            )
        ]
        coordinator.setPrompts(prompts)

        let answer = await coordinator.prompts()
        XCTAssertEqual(answer, prompts, "оба спроса дошли как есть")
        XCTAssertEqual(answer.count, 2, "вектор непустоты")
        guard case .whichMeeting(let seen)? = answer.last?.kind else {
            return XCTFail("ожидался whichMeeting")
        }
        XCTAssertEqual(seen, candidates, "порядок кандидатов не исправлен фейком")
    }

    // MARK: - (в) любой `SessionChange` в поток

    func test_k87_fakeSessionCoordinator_pushesAnyChangeIntoStream() async throws {
        let coordinator = FakeSessionCoordinator()
        let stream = coordinator.changes()          // поток берётся ДО толчка
        let identifier = try XCTUnwrap(sessionId)
        let promptId = UUID()
        let pushed: [SessionChange] = [
            .session(snapshot(id: identifier, state: .scheduled)),
            .promptRaised(SessionPrompt(
                promptId: promptId, sessionId: identifier, kind: .recordThisMeeting,
                raisedAt: Date(timeIntervalSince1970: 0), expiresAt: nil
            )),
            .promptWithdrawn(promptId: promptId),
            .session(snapshot(id: identifier, state: .recording))
        ]
        for change in pushed {
            coordinator.emit(change)
        }
        coordinator.finishChanges()

        var seen: [SessionChange] = []
        for await change in stream {
            seen.append(change)
        }
        XCTAssertEqual(seen.count, 4, "вектор непустоты: поток не пуст и не обрезан")
        XCTAssertEqual(seen, pushed, "значения доходят как есть и в порядке толчка")
    }

    // MARK: - (г) любая команда бросает любую `SessionError`

    func test_k87_fakeSessionCoordinator_everyCommandThrowsAnyGivenError() async throws {
        let identifier = try XCTUnwrap(sessionId)
        let errors: [SessionCommandKind: SessionError] = [
            .startRecording: .alreadyRecording(sessionId: identifier),
            .stopRecording: .noRecordingInProgress(recordingId: identifier),
            .skip: .noSuchMeeting(meetingId: meetingId),
            .answer: .noSuchPrompt(promptId: identifier)
        ]
        XCTAssertEqual(errors.count, SessionCommandKind.allCases.count, "вектор непустоты: перебор полон")

        for kind in SessionCommandKind.allCases {
            let coordinator = FakeSessionCoordinator()
            let expected = try XCTUnwrap(errors[kind])
            coordinator.fail(kind, with: expected)
            await assertThrows(expected, from: coordinator, kind: kind, identifier: identifier)
        }
    }

    func test_k87_fakeSessionCoordinator_capturedErrorIsTheOneGiven() async throws {
        let coordinator = FakeSessionCoordinator()
        let expected = SessionError.capture(.systemAudioDenied)
        coordinator.fail(.startRecording, with: expected)
        do {
            _ = try await coordinator.startRecording(meetingId: meetingId, now: Date(timeIntervalSince1970: 0))
            XCTFail("ожидался отказ")
        } catch let error as SessionError {
            XCTAssertEqual(error, expected, "чужая ошибка C-004 доходит как есть")
        }

        coordinator.fail(.startRecording, with: nil)
        let recordingId = try await coordinator.startRecording(
            meetingId: meetingId, now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(recordingId, FakeSessionCoordinator.deterministicId(1), "отказ снимается")
    }

    // MARK: - (д) все команды с аргументами — списком и в порядке вызовов

    func test_k87_fakeSessionCoordinator_recordsEveryCommandWithArguments() async throws {
        let log = PortCallLog()
        let coordinator = FakeSessionCoordinator(log: log)
        XCTAssertTrue(coordinator.recordedCommands.isEmpty, "вектор непустоты: до вызовов список пуст")

        let moment = Date(timeIntervalSince1970: 1_789_119_000)
        let promptId = UUID()
        let planned = try XCTUnwrap(sessionId)
        coordinator.setNextRecordingIds([planned])

        await coordinator.start(now: moment)
        let recordingId = try await coordinator.startRecording(meetingId: meetingId, now: moment)
        await coordinator.tick(now: moment)
        try await coordinator.stopRecording(recordingId: recordingId, now: moment)
        try await coordinator.skip(meetingId: meetingId, now: moment)
        try await coordinator.answer(promptId: promptId, .skip, now: moment)
        await coordinator.stop()

        XCTAssertEqual(recordingId, planned, "идентификатор — заданный наперёд")
        XCTAssertEqual(
            coordinator.recordedCommands,
            [
                .start(now: moment),
                .startRecording(meetingId: meetingId, now: moment),
                .tick(now: moment),
                .stopRecording(recordingId: planned, now: moment),
                .skip(meetingId: meetingId, now: moment),
                .answer(promptId: promptId, answer: .skip, now: moment),
                .stop
            ],
            "последовательность целиком, с аргументами"
        )
        XCTAssertEqual(log.calls(port: "SessionCoordinator").count, 7, "тот же счёт в общем журнале")
    }

    /// Отказавшая команда всё равно записана: тест обязан видеть, что её ЗВАЛИ.
    func test_k87_fakeSessionCoordinator_recordsCommandsThatThrew() async throws {
        let coordinator = FakeSessionCoordinator()
        coordinator.fail(.skip, with: .noSuchMeeting(meetingId: meetingId))
        let moment = Date(timeIntervalSince1970: 0)
        do {
            try await coordinator.skip(meetingId: meetingId, now: moment)
            XCTFail("ожидался отказ")
        } catch {
            // исход проверен предыдущим вектором; здесь предмет — запись вызова
        }
        XCTAssertEqual(coordinator.recordedCommands, [.skip(meetingId: meetingId, now: moment)])
    }

    // MARK: - Оснастка

    private func snapshot(id: UUID?, state: MeetingStatus) -> SessionSnapshot {
        SessionSnapshot(
            sessionId: id ?? UUID(),
            origin: .scheduled,
            meetingId: meetingId,
            state: state,
            recordingId: nil,
            target: nil,
            estimate: 0.5,
            enteredStateAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func assertThrows(
        _ expected: SessionError,
        from coordinator: FakeSessionCoordinator,
        kind: SessionCommandKind,
        identifier: UUID
    ) async {
        let moment = Date(timeIntervalSince1970: 0)
        do {
            switch kind {
            case .startRecording:
                _ = try await coordinator.startRecording(meetingId: meetingId, now: moment)
            case .stopRecording:
                try await coordinator.stopRecording(recordingId: identifier, now: moment)
            case .skip:
                try await coordinator.skip(meetingId: meetingId, now: moment)
            case .answer:
                try await coordinator.answer(promptId: identifier, .record(sessionId: identifier), now: moment)
            }
            XCTFail("\(kind.rawValue): ожидался отказ")
        } catch let error as SessionError {
            XCTAssertEqual(error, expected, "\(kind.rawValue): ошибка та, что задали")
        } catch {
            XCTFail("\(kind.rawValue): ожидалась SessionError, получено \(error)")
        }
    }
}
