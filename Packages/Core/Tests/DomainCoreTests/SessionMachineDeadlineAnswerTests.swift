//  `nextDeadline(now:)` и согласие плана с поведением — К73 и К74.
//  MEE-307, часть C. Пункты плана MEE-288 §3, раздел И, часть 5/8.
//
//  Файл отделён от `SessionMachineSchedulerTests` по механическому доводу: `--strict` линта
//  считает тело типа длиннее двухсот пятидесяти строк нарушением. Предмет не делится —
//  делится текст.
//
//  СРОК В ПРОШЛОМ ЗАКОНЕН И ОБЯЗАТЕЛЕН, и это здесь проверяется прямо: §10 заставляет
//  первый `tick` после `start(now:)` прийти НЕМЕДЛЕННО именно тем, что восстановленная
//  сессия даёт `nextDeadline(now:)` в прошлом, а §8.5 обязывает composition root звать
//  `tick` не позже ближайшего срока.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineDeadlineAnswerTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
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
