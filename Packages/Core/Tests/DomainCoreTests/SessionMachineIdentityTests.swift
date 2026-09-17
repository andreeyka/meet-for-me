//  Сессия, тождество, терминальность и чтение — К1—К3, К5—К8.
//  MEE-298, часть A. Пункты плана MEE-288 §3, раздел А, часть 2/8.
//
//  Где пункт своего полного ответа в части A не получает, вектор не ослабляется, а
//  опускается, и это названо строкой отчёта: К1 (половина про ad-hoc), К3 (назначение
//  `recordingId` при входе в `recording`), К5 и К6 (состояния `ready` и `failed`),
//  К6 (`stopRecording`, адресованный терминальной сессии) — всё это часть B задачи.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineIdentityTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К1 (инв. 4, первая половина; §1.1, §1.3)

    /// У `origin == .scheduled` `meetingId` равен `MeetingEvent.id` заводившего события и не
    /// `nil` ни в одном состоянии, включая терминальное. Подстановки не происходит ни разу.
    func test_k1_scheduledSessionCarriesTheMeetingIdInEveryReachableState() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let stream = stand.machine.changes()
        await stand.machine.tick(now: moment.addingTimeInterval(-900))  // scheduled
        await stand.machine.tick(now: moment.addingTimeInterval(-300))  // armed
        await stand.machine.tick(now: moment.addingTimeInterval(60))    // awaitingSignal
        await stand.machine.tick(now: moment.addingTimeInterval(1200))  // skipped

        let changes = await collect(stream, count: 4)
        XCTAssertEqual(changes.compactMap { $0.session?.state }, [.scheduled, .armed, .awaitingSignal, .skipped])
        for change in changes {
            XCTAssertEqual(change.session?.meetingId, event.id, "в каждом снимке, включая терминальный")
            XCTAssertEqual(change.session?.origin, .scheduled)
        }
    }

    // MARK: - К2 (инв. 4, вторая половина)

    /// Ветвь (а): пока первая сессия жива, второй не появляется ни одной из трёх попыток.
    /// Ветвь (б): после того как она стала терминальной, — тоже (и это уже инвариант 24).
    func test_k2_noSecondSessionWhileAliveAndNoneAfterTerminal() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.start(now: moment.addingTimeInterval(-900))
        await stand.machine.tick(now: moment.addingTimeInterval(-900))

        // (а) повторный `tick`, повторный `CalendarChange`, повторный `start`.
        stand.calendar.emit(.upserted([event]))
        await stand.awaitDelivery(1)
        await stand.machine.start(now: moment.addingTimeInterval(-880))
        await stand.machine.tick(now: moment.addingTimeInterval(-880))
        let probe0 = await stand.machine.sessions().count
        XCTAssertEqual(probe0, 1, "(а): не более одной нетерминальной")

        // (б) те же три попытки после ухода в терминальное состояние.
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(-870))
        stand.calendar.emit(.upserted([event]))
        await stand.awaitDelivery(2)
        await stand.machine.start(now: moment.addingTimeInterval(-860))
        await stand.machine.tick(now: moment.addingTimeInterval(-860))
        let probe1 = await stand.machine.sessions().isEmpty
        XCTAssertTrue(probe1, "(б): вторая не заводится ни одной попыткой")
        await stand.machine.stop()
    }

    // MARK: - К3 (инв. 5; §1.3)

    /// `recordingId == nil` во всех состояниях ДО `recording`, и часть A других не заводит.
    func test_k3_recordingIdStaysNilOnEveryPathOfThisPart() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let stream = stand.machine.changes()
        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        await stand.machine.tick(now: moment.addingTimeInterval(1500))

        let changes = await collect(stream, count: 2)
        XCTAssertEqual(changes.count, 2)
        for change in changes {
            XCTAssertNil(change.session?.recordingId, "до входа в `recording` номера записи нет")
        }
    }

    // MARK: - К5 (инв. 3)

    /// Терминальная сессия не меняется НИ ОДНИМ входом §2 и ошибки ни один не даёт.
    /// Достижимое терминальное состояние части A одно — `skipped`.
    func test_k5_terminalSessionIgnoresEveryInput() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.start(now: moment.addingTimeInterval(-900))
        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        let probe2 = await stand.machine.sessions().first?.sessionId
        let identifier = try XCTUnwrap(probe2)
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(-880))

        stand.processes.emit(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: moment))
        let refreshed = try SessionMachineFixtures.event(id: event.id)
        stand.calendar.emit(.upserted([refreshed]))
        stand.calendar.emit(.deleted([event.id]))
        stand.capture.emit(.systemSilent(sinceMs: 0))
        stand.queue.emit(.blocked(jobId: UUID(), type: .transcode, reason: .recordingInProgress))
        stand.power.emit(.didWake)
        stand.power.emit(.willSleep)
        await stand.awaitDelivery(7)
        await stand.machine.tick(now: moment.addingTimeInterval(9000))

        let probe3 = await stand.machine.session(id: identifier)
        let snapshot = try XCTUnwrap(probe3)
        XCTAssertEqual(snapshot.state, .skipped, "состояние не изменилось ни на одном входе")
        let probe4 = await stand.machine.sessions().isEmpty
        XCTAssertTrue(probe4)
        await stand.machine.stop()
    }

    // MARK: - К6 (инв. 3, вторая половина; §3.1 `SessionError`)

    /// Команды, адресованные терминальной сессии, бросают `sessionIsTerminal` со ФАКТИЧЕСКИМ
    /// состоянием. Не `noSuchSession`, не `noSuchPrompt`, не молчаливый успех.
    func test_k6_commandsToATerminalSessionThrowSessionIsTerminal() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-60))   // armed + спрос по `askAt`
        let probe5 = await stand.machine.prompts().first
        let prompt = try XCTUnwrap(probe5)
        let probe6 = await stand.machine.sessions().first?.sessionId
        let identifier = try XCTUnwrap(probe6)
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(-50))

        await assertSessionIsTerminal(identifier, body: {
            _ = try await stand.machine.startRecording(meetingId: event.id, now: self.moment)
        })
        await assertSessionIsTerminal(identifier, body: {
            try await stand.machine.skip(meetingId: event.id, now: self.moment)
        })
        await assertSessionIsTerminal(identifier, body: {
            try await stand.machine.answer(promptId: prompt.promptId, .skip, now: self.moment)
        })
    }

    private func assertSessionIsTerminal(
        _ identifier: UUID,
        body: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await body()
            XCTFail("команда обязана бросить, а не вернуться молча", file: file, line: line)
        } catch let error as SessionError {
            XCTAssertEqual(
                error,
                SessionError.sessionIsTerminal(sessionId: identifier, state: .skipped),
                "и тип, и `state` — фактические",
                file: file,
                line: line
            )
        } catch {
            XCTFail("не `SessionError`: \(error)", file: file, line: line)
        }
    }

    // MARK: - К7 (§1.3)

    /// `sessionId` назначается при заведении и не меняется ни одним переходом, включая
    /// возврат `armed → scheduled` строкой 5 и пересчёт сроков §9.2.
    func test_k7_sessionIdSurvivesEveryTransitionIncludingRow5() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.start(now: moment.addingTimeInterval(-300))
        await stand.machine.tick(now: moment.addingTimeInterval(-300))
        let probe7 = await stand.machine.sessions().first?.sessionId
        let opened = try XCTUnwrap(probe7)

        let shifted = try SessionMachineFixtures.event(id: event.id, start: moment.addingTimeInterval(3600))
        stand.calendar.emit(.upserted([shifted]))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: moment.addingTimeInterval(-290))       // строка 5
        await stand.machine.tick(now: moment.addingTimeInterval(3300))       // строка 2 по новому окну
        await stand.machine.tick(now: moment.addingTimeInterval(3600 + 1200))  // строка 9

        let all = await stand.machine.session(id: opened)
        XCTAssertEqual(all?.sessionId, opened, "сессия не пересоздана ни одним переходом")
        XCTAssertEqual(all?.state, .skipped)
        await stand.machine.stop()
    }

    // MARK: - К8 (§3.1 «Чтение»)

    /// Порядок заведения намеренно ПРОТИВОПОЛОЖЕН порядку `sessionId` — иначе вектор не
    /// отличает «по возрастанию `sessionId`» от «в порядке заведения».
    func test_k8_readsAreSortedByIdAndTerminalOnesAreReadableById() async throws {
        let stand = try bench()
        let first = try SessionMachineFixtures.event(id: UUID(uuidString: "FFFFFFFF-0000-4000-8000-000000000001")!)
        let second = try SessionMachineFixtures.event(id: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
        stand.seed(first)
        stand.seed(second)

        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        let live = await stand.machine.sessions()
        XCTAssertEqual(live.count, 2)
        XCTAssertTrue(
            live[0].sessionId.uuidString < live[1].sessionId.uuidString,
            "`sessions()` отдаёт по возрастанию `sessionId`"
        )

        try await stand.machine.skip(meetingId: first.id, now: moment.addingTimeInterval(-880))
        let afterSkip = await stand.machine.sessions()
        XCTAssertEqual(afterSkip.count, 1, "`sessions()` отдаёт только нетерминальные")

        let terminal = try XCTUnwrap(live.first { $0.meetingId == first.id }?.sessionId)
        let probe8 = await stand.machine.session(id: terminal)
        XCTAssertNotNil(probe8, "`session(id:)` отдаёт и терминальную")
        let probe9 = await stand.machine.session(id: UUID())
        XCTAssertNil(probe9, "и `nil` на незнакомом")
        let probe10 = await stand.machine.prompts().isEmpty
        XCTAssertTrue(probe10, "при `.auto` спросов нет ни одного")
    }
}
