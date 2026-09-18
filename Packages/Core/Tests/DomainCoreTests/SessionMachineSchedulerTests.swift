//  `Scheduler` — К70, К71, К72, К73, К74.
//  MEE-307, часть C. Пункты плана MEE-288 §3, раздел И, часть 5/8.
//
//  ОБЛАСТЬ ПУНКТОВ — ПОВЕДЕНЧЕСКАЯ, И СРЕДСТВО У НЕЁ ОДНО: `plan(now:)` и
//  `nextDeadline(now:)` объявлены §3.2 РАДИ ПРОВЕРЯЕМОСТИ, и контракт говорит это вслух —
//  «„взвелось ли за две минуты до начала“ есть вопрос, на который реальные часы отвечают
//  двумя минутами, а `plan` отвечает сразу и на любом входе». Ни один вектор здесь не ждёт
//  ни секунды: всякий момент задан тестом (§4).

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineSchedulerTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К70 (§3.2, `ScheduledArm`)

    /// Пять полей — пять отдельных проверок, и настройки ВСЕ отличны от умолчаний C-016
    /// (120, 30, 900, 300): реализация, зашившая число, зелена на умолчаниях и красна здесь.
    func test_k70_everyFieldOfScheduledArmFollowsItsSetting() throws {
        let settings = SessionMachineFixtures.settings(
            policy: .ask, armLead: 600, askLead: 90, grace: 1200, silence: 240
        )
        let event = try SessionMachineFixtures.event()
        let arm = SessionMachineRules.arm(for: event, settings: settings)

        XCTAssertEqual(arm.meetingId, event.id)
        XCTAssertEqual(arm.armAt, event.start.addingTimeInterval(-600), "armAt == start − armLead")
        XCTAssertEqual(arm.askAt, event.start.addingTimeInterval(-90), "askAt == start − askLead")
        XCTAssertEqual(arm.startsAt, event.start, "startsAt == MeetingEvent.start")
        XCTAssertEqual(arm.endsAt, event.end, "endsAt == MeetingEvent.end")
        XCTAssertEqual(
            arm.graceEndsAt, event.start.addingTimeInterval(1200), "graceEndsAt == start + grace"
        )
    }

    /// `askAt` равен `nil` при ВСЕХ политиках, кроме `.ask`, и это отдельная проверка:
    /// перебор идёт по трём значениям, а не по одному отрицательному.
    func test_k70_askAtIsNilUnderEveryPolicyButAsk() throws {
        let event = try SessionMachineFixtures.event()
        for policy in [AppSettings.RecordingPolicy.auto, .manual] {
            let arm = SessionMachineRules.arm(
                for: event, settings: SessionMachineFixtures.settings(policy: policy)
            )
            XCTAssertNil(arm.askAt, "\(policy): `askAt == nil`")
        }
        let asking = SessionMachineRules.arm(
            for: event, settings: SessionMachineFixtures.settings(policy: .ask)
        )
        XCTAssertNotNil(asking.askAt, "`.ask`: `askAt` заполнен")
    }

    // MARK: - К71 (§3.2, `plan(now:)`; §9.1, последний пункт — разобран изданием v6)

    /// Хранимый `MeetingStatus` перебирается по ВСЕМ ДЕВЯТИ значениям: на шести
    /// нетерминальных строка в плане есть, на трёх терминальных — нет ни одной.
    /// Вектор (а) издания v6: до него терминальных не подавал ни один пункт.
    func test_k71_a_terminalStoredStatusKeepsTheMeetingOutOfThePlan() async throws {
        let statuses: [MeetingStatus] = [
            .scheduled, .armed, .awaitingSignal, .recording, .stopping, .processing,
            .ready, .failed, .skipped
        ]
        for status in statuses {
            let stand = try bench()
            let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
            stand.seed(event, status: status)

            let plan = try await stand.machine.plan(now: moment)
            if status.isTerminalSession {
                XCTAssertEqual(plan.count, 0, "\(status): строки в плане нет ни одной")
            } else {
                XCTAssertEqual(plan.map(\.meetingId), [event.id], "\(status): строка в плане есть")
            }
        }
    }

    /// Вектор (б) издания v6 и он НЕСУЩИЙ: у встречи ЕСТЬ живая сессия — строка в плане
    /// ВСЁ РАВНО ЕСТЬ. Клауза «у встречи нет живой сессии» к `plan(now:)` не применяется, и
    /// сказано это §9.1 дословно. Реализация, сузившая план до встреч без живой сессии,
    /// делает ветвь инварианта 17 «заведённая раньше и живая» недостижимой (К74).
    func test_k71_b_aMeetingWithALiveSessionStaysInThePlan() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
        stand.seed(event)
        await stand.machine.start(now: moment)
        await stand.machine.tick(now: moment)

        let live = await stand.machine.sessions()
        XCTAssertEqual(live.count, 1, "оснастка: живая сессия у встречи есть")
        let plan = try await stand.machine.plan(now: moment)
        XCTAssertEqual(plan.map(\.meetingId), [event.id], "строка плана есть и при живой сессии")
        await stand.machine.stop()
    }

    /// Окно `now ≤ graceEndsAt`: прошёл, равен `now`, впереди. Порядок — по возрастанию
    /// `armAt`, при равенстве — по `meetingId`. Вызов сессий не заводит и состояния ни
    /// одной не меняет.
    func test_k71_theWindowTheOrderAndThePurityOfTheAnswer() async throws {
        let stand = try bench()
        let settings = SessionMachineFixtures.settings()
        let past = try SessionMachineFixtures.event(
            start: moment.addingTimeInterval(-TimeInterval(settings.missingSignalGraceSeconds) - 1)
        )
        let edge = try SessionMachineFixtures.event(
            start: moment.addingTimeInterval(-TimeInterval(settings.missingSignalGraceSeconds))
        )
        let ahead = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
        // Две встречи с РАВНЫМ `armAt` и разными `meetingId`: их разводит вторая ступень.
        let twinA = try SessionMachineFixtures.event(start: moment.addingTimeInterval(7200))
        let twinB = try SessionMachineFixtures.event(start: moment.addingTimeInterval(7200))
        for event in [past, edge, ahead, twinA, twinB] { stand.seed(event) }

        let plan = try await stand.machine.plan(now: moment)
        XCTAssertFalse(
            plan.contains { $0.meetingId == past.id }, "`now > graceEndsAt` — строки нет"
        )
        XCTAssertTrue(
            plan.contains { $0.meetingId == edge.id }, "`now == graceEndsAt` — строка есть"
        )

        let armMoments = plan.map(\.armAt)
        XCTAssertEqual(armMoments, armMoments.sorted(), "по возрастанию `armAt`")
        let twins = plan.filter { $0.meetingId == twinA.id || $0.meetingId == twinB.id }
        XCTAssertEqual(twins.count, 2, "обе близнецовые строки на месте")
        XCTAssertEqual(
            twins.map(\.meetingId),
            twins.map(\.meetingId).sorted { SessionMachineOrder.ascending($0, $1) },
            "при равенстве `armAt` — по возрастанию `meetingId`"
        )
        let sessions = await stand.machine.sessions()
        XCTAssertTrue(sessions.isEmpty, "`plan(now:)` сессий не заводит ни одной")
    }

    /// `isAllDay` и `isCancelled` — две первые клаузы, и каждая снимает строку сама.
    func test_k71_allDayAndCancelledEventsAreNotPlanned() async throws {
        let stand = try bench()
        let allDay = try SessionMachineFixtures.event(
            start: moment.addingTimeInterval(3600), isAllDay: true
        )
        let cancelled = try SessionMachineFixtures.event(
            start: moment.addingTimeInterval(3600), isCancelled: true
        )
        let plain = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
        for event in [allDay, cancelled, plain] { stand.seed(event) }

        let plan = try await stand.machine.plan(now: moment)
        XCTAssertEqual(plan.map(\.meetingId), [plain.id], "в плане только годное событие")
    }

    // MARK: - К72 (инв. 16)

    /// Чистая функция: повторный вызов даёт равный ответ поэлементно; порядок ответа не
    /// зависит от порядка строк хранилища; состояния ни одной сессии вызов не меняет.
    func test_k72_planIsAPureFunctionOfStorageSettingsAndNow() async throws {
        let forward = try bench()
        let backward = try bench()
        let events = try (0..<5).map { index in
            try SessionMachineFixtures.event(start: moment.addingTimeInterval(600 * Double(index + 1)))
        }
        for event in events { forward.seed(event) }
        for event in events.reversed() { backward.seed(event) }

        let first = try await forward.machine.plan(now: moment)
        let second = try await forward.machine.plan(now: moment)
        XCTAssertEqual(first, second, "повторный вызов даёт равный ответ поэлементно")
        let reversed = try await backward.machine.plan(now: moment)
        XCTAssertEqual(first, reversed, "ответ не зависит от порядка строк хранилища")
        XCTAssertEqual(first.count, events.count, "вектор непустоты: строк столько же")
    }

    /// Параллельные вызовы дают тот же ответ: актор сериализует их, и общего состояния,
    /// которое `plan` мог бы испортить, у него нет.
    func test_k72_parallelCallsAnswerTheSame() async throws {
        let stand = try bench()
        for index in 0..<4 {
            stand.seed(try SessionMachineFixtures.event(
                start: moment.addingTimeInterval(600 * Double(index + 1))
            ))
        }
        let expected = try await stand.machine.plan(now: moment)
        async let left = stand.machine.plan(now: moment)
        async let right = stand.machine.plan(now: moment)
        let answers = try await [left, right]
        XCTAssertEqual(answers[0], expected)
        XCTAssertEqual(answers[1], expected)
    }

    // MARK: - К73 (инв. 15)

    /// `nil` ТОГДА И ТОЛЬКО ТОГДА, когда сроков нет ни одного, — обе половины.
    func test_k73_nilExactlyWhenThereIsNoDeadlineAtAll() async throws {
        let empty = try bench()
        let nothing = try await empty.machine.nextDeadline(now: moment)
        XCTAssertNil(nothing, "сроков нет — `nil`")

        let stand = try bench()
        stand.seed(try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600)))
        let some = try await stand.machine.nextDeadline(now: moment)
        XCTAssertNotNil(some, "срок есть — не `nil`")
    }

    /// Не больше ближайшего `armAt` из `plan(now:)` — и на встрече, до которой ещё далеко.
    func test_k73_nextDeadlineIsNotGreaterThanTheNearestPlannedArm() async throws {
        let stand = try bench()
        for offset in [3600.0, 7200.0, 10_800.0] {
            stand.seed(try SessionMachineFixtures.event(start: moment.addingTimeInterval(offset)))
        }
        let plan = try await stand.machine.plan(now: moment)
        let nearest = try unwrap(plan.map(\.armAt).min())
        let deadline = try unwrap(try await stand.machine.nextDeadline(now: moment))
        XCTAssertLessThanOrEqual(deadline, nearest, "не больше ближайшего `armAt` плана")
    }

    /// Не больше ближайшего срока ЖИВОЙ сессии. Сессия взведена, её ближайший срок —
    /// `e.start` (строка 7), и `nextDeadline` его не перескакивает.
    func test_k73_nextDeadlineIsNotGreaterThanTheNearestLiveSessionDeadline() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(300))
        stand.seed(event)
        await stand.machine.start(now: moment)
        await stand.machine.tick(now: moment)
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .armed, "оснастка: сессия взведена")

        let arm = SessionMachineRules.arm(for: event, settings: SessionMachineFixtures.settings())
        let deadline = try unwrap(try await stand.machine.nextDeadline(now: moment))
        XCTAssertLessThanOrEqual(deadline, arm.startsAt, "не больше ближайшего срока сессии")
        await stand.machine.stop()
    }

    /// СРОК В ПРОШЛОМ ЗАКОНЕН И ОБЯЗАТЕЛЕН: сессия, восстановленная §10 при уже прошедшем
    /// `graceEndsAt`, даёт `nextDeadline(now:)` В ПРОШЛОМ — этим §10 и заставляет первый
    /// `tick` прийти немедленно (§8.5). Реализация, подрезающая ответ до `now`, оставила бы
    /// её ждать общего периода.
    func test_k73_aPassedDeadlineIsReturnedAsIsAndNotClampedToNow() async throws {
        let stand = try bench()
        let settings = SessionMachineFixtures.settings()
        let event = try SessionMachineFixtures.event(
            start: moment.addingTimeInterval(-TimeInterval(settings.missingSignalGraceSeconds))
        )
        stand.seed(event, status: .awaitingSignal)
        await stand.machine.start(now: moment)

        let arm = SessionMachineRules.arm(for: event, settings: settings)
        XCTAssertLessThanOrEqual(arm.graceEndsAt, moment, "оснастка: срок уже наступил")
        let deadline = try unwrap(try await stand.machine.nextDeadline(now: moment))
        XCTAssertLessThanOrEqual(deadline, moment, "срок отдан как есть, а не подрезан до `now`")
        await stand.machine.stop()
    }

    // MARK: - К74 (инв. 17)

    /// Согласие тотально по строкам плана, и состояние заведённой сессии есть функция от
    /// `now` заведения: `now < armAt` — `scheduled`; `armAt ≤ now < startsAt` — СРАЗУ
    /// `armed`; `startsAt ≤ now ≤ graceEndsAt` — СРАЗУ `awaitingSignal`.
    func test_k74_everyPlanRowHasItsSessionByTheFirstTickInTheStateOfNow() async throws {
        let settings = SessionMachineFixtures.settings()
        let probes: [(TimeInterval, MeetingStatus)] = [
            (-TimeInterval(settings.armLeadSeconds) - 60, .scheduled),
            (-TimeInterval(settings.armLeadSeconds) + 60, .armed),
            (60, .awaitingSignal)
        ]
        for (offset, expected) in probes {
            let stand = try bench()
            // Событие стоит так, чтобы `moment + offset` попал в нужный отрезок.
            let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(-offset))
            stand.seed(event)

            let plan = try await stand.machine.plan(now: moment)
            XCTAssertEqual(plan.map(\.meetingId), [event.id], "оснастка: строка плана есть")

            await stand.machine.start(now: moment)
            await stand.machine.tick(now: moment)
            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.meetingId, event.id, "сессия встречи существует")
            XCTAssertEqual(live.state, expected, "состояние есть функция от `now` заведения")
            await stand.machine.stop()
        }
    }

    /// Вектор (а): у встречи ЕСТЬ живая сессия — новой не заводится ни одной, и это
    /// единственный вход, которым достижима ветвь «заведённая раньше и живая».
    func test_k74_a_aLivePlanRowOpensNoSecondSession() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
        stand.seed(event)
        await stand.machine.start(now: moment)
        await stand.machine.tick(now: moment)
        let first = await stand.machine.sessions()
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let second = await stand.machine.sessions()

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1, "второй сессии не заводится ни одной")
        XCTAssertEqual(first.first?.sessionId, second.first?.sessionId, "она же самая")
        let plan = try await stand.machine.plan(now: moment.addingTimeInterval(60))
        XCTAssertEqual(plan.count, 1, "а строка плана при этом на месте (К71 вектор (б))")
        await stand.machine.stop()
    }

    /// Вектор (б): хранимый `MeetingStatus` терминален — строки плана нет ни одной, и
    /// подать через план эту встречу нечем; заведения тоже не наблюдается ни одного.
    func test_k74_b_aTerminalMeetingHasNeitherPlanRowNorSession() async throws {
        for status in [MeetingStatus.ready, .failed, .skipped] {
            let stand = try bench()
            let event = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
            stand.seed(event, status: status)

            let plan = try await stand.machine.plan(now: moment)
            XCTAssertTrue(plan.isEmpty, "\(status): строки плана нет ни одной")
            await stand.machine.start(now: moment)
            await stand.machine.tick(now: moment)
            let sessions = await stand.machine.sessions()
            XCTAssertTrue(sessions.isEmpty, "\(status): и заведения нет ни одного")
            await stand.machine.stop()
        }
    }

    /// Ad-hoc-сессий инвариант 17 не касается ни одной: события у них нет, и строк плана
    /// они не дают (К95, К97).
    func test_k74_adHocSessionsAreNotPlanned() async throws {
        let stand = try bench()
        await stand.machine.start(now: moment)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment
        ))
        await stand.machine.tick(now: moment)
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.origin, .adHoc, "оснастка: ad-hoc-сессия заведена")

        let plan = try await stand.machine.plan(now: moment)
        XCTAssertTrue(plan.isEmpty, "строк плана ad-hoc-сессия не даёт ни одной")
        await stand.machine.stop()
    }
}
