//  Окончание спора без ответа и занятая цель — К98, К94, и правка К24 издания v7.
//  MEE-307, часть C. Пункты плана MEE-288 §3, раздел Д.
//
//  К99 (§3.1 `SessionPrompt.expiresAt` вида `.whichMeeting`) заведён изданием v8 (MEE-276,
//  «Новые места v8», MEE-341) и живёт здесь же — оснастка спора уже есть в этом файле, и
//  второго её описания не заводится.
//
//  ДВА ПУНКТА ЗДЕСЬ НЕ ПОДАВАЛИСЬ ДЕРЕВОМ НИ ОДНИМ ВЕКТОРОМ. К98 заведён изданием v7 и не
//  мог иметь их по построению; К94 требует, чтобы держателем занятой цели выступала
//  ad-hoc-сессия, а до правила `1а` §5.4 у ad-hoc-сессии не было цели вовсе.
//
//  И ОДНА ПРАВКА ОЖИДАЕМОГО ПОВЕДЕНИЯ, ВЫШЕДШАЯ ПОСЛЕ ЧАСТЕЙ A И B: спором с издания v7
//  является отнесение сигнала к двум и более сессиям ПРАВИЛОМ 2 ЛИБО ПРАВИЛОМ 3 — по ЧИСЛУ
//  отнесённых сессий, а не по номеру отнёсшего правила. Прежняя редакция называла спором
//  отнесение правилом 3 и разрешала его тем, что «правило 2 отнесло цель ровно к одной
//  сессии», — а правила 2 и 3 взаимно исключаются по `s.provider`, то есть названная ветвь
//  была мертва, и два пересекающихся созвона ОДНОГО провайдера под определение не попадали
//  вовсе (К24, К25).

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineDisputeEndTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    /// Стенд спора: две сессии ОДНОГО провайдера с пересекающимися окнами. Значением, а не
    /// кортежем: линт считает кортеж длиннее двух членов нарушением, и тот же довод уже
    /// назван у `Row8Vector` в `SessionMachineEntryTests`.
    private struct DisputeStand {
        let stand: SessionMachineBench
        let first: MeetingEvent
        let second: MeetingEvent
    }

    /// Цель относится к обеим сессиям правилом 2. Ответ — обе живы, спор поднят.
    private func standWithTwoSessionsOfOneProvider(
        policy: AppSettings.RecordingPolicy = .auto
    ) throws -> DisputeStand {
        let stand = try bench(policy: policy)
        let first = try SessionMachineFixtures.event(provider: "zoom")
        let second = try SessionMachineFixtures.event(
            start: moment.addingTimeInterval(300), provider: "zoom"
        )
        stand.seed(first)
        stand.seed(second)
        return DisputeStand(stand: stand, first: first, second: second)
    }

    // MARK: - К24, правка издания v7: спор поднимается и при отнесении правилом 2

    /// ДВА ПЕРЕСЕКАЮЩИХСЯ СОЗВОНА ОДНОГО ПРОВАЙДЕРА СПРАШИВАЮТ ЧЕЛОВЕКА ВСЕГДА, и это цена,
    /// названная §5.4 прямо. До издания v7 этот вход спором не был: признак стоял на НОМЕРЕ
    /// правила, а правило 2 из определения выпадало, — и машина молча отдавала цель одной
    /// стороне, а вторая уходила в `skipped` по клаузе «цель занята».
    func test_k24_v7_twoOverlappingCallsOfOneProviderAlwaysAskTheHuman() async throws {
        let now = moment.addingTimeInterval(400)
        let staged = try standWithTwoSessionsOfOneProvider()
        let stand = staged.stand
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        let probe1 = await stand.machine.sessions()
        XCTAssertEqual(probe1.count, 2, "оснастка: обе сессии живы")

        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, provider: "zoom"
        ))
        await stand.machine.tick(now: now)

        let prompts = await stand.machine.prompts()
        XCTAssertEqual(prompts.count, 1, "спор поднят — один спрос на спор")
        guard case let .whichMeeting(candidates) = try unwrap(prompts.first?.kind) else {
            return XCTFail("вид спроса — `.whichMeeting`")
        }
        XCTAssertEqual(candidates.count, 2, "сторон две, и обе отнесены ПРАВИЛОМ 2")
        for session in await stand.machine.sessions() {
            XCTAssertNil(session.target, "до ответа оспариваемая цель не принадлежит ни одной")
            XCTAssertNotEqual(session.state, .recording, "и не записывает ни одна")
        }
        XCTAssertEqual(stand.capture.recordedCalls.count, 0, "захват не зван ни разу")
        await stand.machine.stop()
    }

    // MARK: - К98 (§5.4, второй способ окончания спора — издание v7)

    /// Способ (а): сигнал ВЫПАЛ ПО СРОКУ (C-009, инвариант 25). Момент подаётся точно:
    /// `observedAt` последней публикации равен `t`, машина замечает это на `tick` в
    /// `t + signalTtlSeconds + δ` при `δ > 0`. Отнесённой не остаётся НИ ОДНОЙ: спрос снят,
    /// и каждая сторона идёт своим путём по строке 9.
    func test_k98_a_theSignalFallsOutByTtlAndThePromptIsWithdrawn() async throws {
        let weights = try SessionMachineFixtures.weights()
        let now = moment.addingTimeInterval(400)
        let staged = try standWithTwoSessionsOfOneProvider()
        let stand = staged.stand
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, provider: "zoom"
        ))
        await stand.machine.tick(now: now)
        let promptId = try unwrap(await stand.machine.prompts().first?.promptId)

        // Поток берётся ЗДЕСЬ, а не в начале: при подписке он отдаёт снимок — две живые
        // сессии и один поднятый спрос (инвариант 21), — и потому счёт элементов известен
        // точно и не зависит от того, сколько публикаций было прежде.
        let stream = stand.machine.changes()
        let after = now.addingTimeInterval(TimeInterval(weights.signalTtlSeconds) + 1)
        await stand.machine.tick(now: after)

        let probe2 = await stand.machine.prompts()
        XCTAssertTrue(
            probe2.isEmpty,
            "спрос снят МАШИНОЙ, а не ответом человека: `prompts()` его больше не отдаёт"
        )
        let seen = await collect(stream, count: 4)
        XCTAssertEqual(
            seen.compactMap(\.withdrawnPromptId), [promptId],
            "в `changes()` пришёл `promptWithdrawn` того самого спроса"
        )
        await stand.machine.stop()
    }

    /// Способ (б): одна из сторон стала ТЕРМИНАЛЬНОЙ. Отнесённой осталась РОВНО ОДНА —
    /// и цель становится ЕЁ звучащей целью со всеми последствиями строк 6 и 8: при
    /// свободной цели и отдающей политике она уходит в `recording` ТЕМ ЖЕ `tick`.
    func test_k98_b_oneSideGoesTerminalAndTheOtherGetsTheTargetSameTick() async throws {
        let now = moment.addingTimeInterval(400)
        let staged = try standWithTwoSessionsOfOneProvider()
        let stand = staged.stand
        stand.allowCaptureStart()
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, provider: "zoom"
        ))
        await stand.machine.tick(now: now)
        let probe3 = await stand.machine.prompts()
        XCTAssertEqual(probe3.count, 1, "оснастка: спор поднят")

        // Одну сторону уводит в терминальное состояние команда человека.
        try await stand.machine.skip(meetingId: staged.first.id, now: now)
        let later = now.addingTimeInterval(1)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: later, provider: "zoom"
        ))
        await stand.machine.tick(now: later)

        let probe4 = await stand.machine.prompts()
        XCTAssertTrue(probe4.isEmpty, "спрос снят машиной")
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.meetingId, staged.second.id, "осталась ровно одна сторона")
        XCTAssertEqual(live.target?.appKey, "us.zoom.xos", "и цель стала ЕЁ звучащей целью")
        XCTAssertEqual(live.state, .recording, "со всеми последствиями строк 6 и 8 — тем же `tick`")
        await stand.machine.stop()
    }

    /// Способ (в): у одной из сторон ЗАКРЫЛОСЬ ОКНО `armAt ≤ now ≤ graceEndsAt`, и она не в
    /// `recording`/`stopping`. Отнесённой остаётся ровно одна, и спрос снимается.
    func test_k98_c_oneWindowClosesAndTheDisputeEnds() async throws {
        let stand = try bench()
        stand.allowCaptureStart()
        let settings = SessionMachineFixtures.settings()
        let early = try SessionMachineFixtures.event(provider: "zoom")
        let late = try SessionMachineFixtures.event(
            start: moment.addingTimeInterval(900), provider: "zoom"
        )
        stand.seed(early)
        stand.seed(late)
        let now = moment.addingTimeInterval(500)
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, provider: "zoom"
        ))
        await stand.machine.tick(now: now)
        let probe5 = await stand.machine.prompts()
        XCTAssertEqual(probe5.count, 1, "оснастка: спор поднят")

        // Окно ранней встречи — `armAt ≤ now ≤ graceEndsAt`, и В САМ `graceEndsAt` она ещё
        // В НЁМ: знак верхней границы нестрогий. Закрывается оно строго ПОСЛЕ, и берётся
        // здесь именно этот момент — иначе сторон по-прежнему две, а спор не кончился.
        let closing = SessionMachineRules.arm(for: early, settings: settings)
            .graceEndsAt.addingTimeInterval(1)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: closing, provider: "zoom"
        ))
        await stand.machine.tick(now: closing)

        let probe6 = await stand.machine.prompts()
        XCTAssertTrue(probe6.isEmpty, "спрос снят: сторона осталась одна")
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.meetingId, late.id, "осталась поздняя встреча")
        XCTAssertEqual(live.target?.appKey, "us.zoom.xos", "и цель досталась ей")
        await stand.machine.stop()
    }

    /// ОТРИЦАТЕЛЬНЫЙ ВЕКТОР: цель опубликована СНОВА до истечения срока, обе стороны живы и
    /// в окне — спрос НЕ СНИМАЕТСЯ, и ни одна не записывает. `promptWithdrawn` не приходит
    /// ни одного.
    func test_k98_negative_aRepublishedTargetKeepsTheDisputeAlive() async throws {
        let now = moment.addingTimeInterval(400)
        let staged = try standWithTwoSessionsOfOneProvider()
        let stand = staged.stand
        stand.allowCaptureStart()
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, provider: "zoom"
        ))
        await stand.machine.tick(now: now)
        let promptId = try unwrap(await stand.machine.prompts().first?.promptId)

        for step in 1...3 {
            let at = now.addingTimeInterval(Double(step) * 10)
            await stand.deliver(SessionMachineFixtures.audioOutput(
                appKey: "us.zoom.xos", observedAt: at, provider: "zoom"
            ))
            await stand.machine.tick(now: at)
        }

        let prompts = await stand.machine.prompts()
        XCTAssertEqual(prompts.count, 1, "спрос НЕ снимается")
        XCTAssertEqual(prompts.first?.promptId, promptId, "и он тот же самый")
        for session in await stand.machine.sessions() {
            XCTAssertNotEqual(session.state, .recording, "и ни одна не записывает")
        }
        XCTAssertEqual(stand.capture.recordedCalls.count, 0, "захват не зван ни разу")
        await stand.machine.stop()
    }

    // MARK: - К99 (§3.1 `SessionPrompt.expiresAt`, вид `.whichMeeting`; издание v8)

    /// `expiresAt == nil` во всякий момент жизни спроса `.whichMeeting`, без исключения:
    /// сразу после подъёма, посреди спора (до истечения `graceEndsAt` любого кандидата, тем
    /// же входом, что и К98, отрицательный вектор) и по его завершении. Спрос при этом
    /// снимается СОБЫТИЕМ МАШИНЫ в момент, когда спор кончается (способ (б) §5.4, К98) —
    /// а не истечением срока, которого у самого спроса нет ни одного.
    func test_k99_whichMeetingPromptNeverCarriesAnExpiryAtAnyMomentOfItsLife() async throws {
        let now = moment.addingTimeInterval(400)
        let staged = try standWithTwoSessionsOfOneProvider()
        let stand = staged.stand
        stand.allowCaptureStart()
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, provider: "zoom"
        ))
        await stand.machine.tick(now: now)

        let raised = try unwrap(await stand.machine.prompts().first)
        guard case .whichMeeting = raised.kind else {
            return XCTFail("оснастка: вид спроса — `.whichMeeting`")
        }
        XCTAssertNil(raised.expiresAt, "сразу после подъёма")
        let promptId = raised.promptId

        // Посреди спора: цель опубликована снова до истечения `graceEndsAt` любой стороны —
        // спор жив, спрос тот же.
        let midway = now.addingTimeInterval(10)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: midway, provider: "zoom"
        ))
        await stand.machine.tick(now: midway)
        let stillRaised = try unwrap(await stand.machine.prompts().first { $0.promptId == promptId })
        XCTAssertEqual(stillRaised.promptId, promptId, "оснастка: спрос всё ещё тот же")
        XCTAssertNil(stillRaised.expiresAt, "посреди спора, до истечения `graceEndsAt` любого кандидата")

        // Завершение способом (б) §5.4: одна сторона стала терминальной командой человека.
        try await stand.machine.skip(meetingId: staged.first.id, now: midway)
        let after = midway.addingTimeInterval(1)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: after, provider: "zoom"
        ))
        await stand.machine.tick(now: after)

        XCTAssertTrue(
            await stand.machine.prompts().isEmpty,
            "спрос снят по завершении спора — событием машины, а не истечением `expiresAt`"
        )
        await stand.machine.stop()
    }

    /// ОТРИЦАТЕЛЬНЫЙ ВЕКТОР К99: тот же прогон на спросе `.recordThisMeeting` (К60, К95) —
    /// значение то же (`nil`), и ПО ТОЙ ЖЕ ПРИЧИНЕ КЛАССА (§3.1: «держится, пока держится
    /// причина»), а не совпадением. В дереве нет ни одного места, строящего `SessionPrompt`
    /// с непустым `expiresAt`, ни для одного вида.
    func test_k99_negative_recordThisMeetingPromptAnswersTheSameNilByTheSameReason() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-90))   // askAt = T − 90

        let prompt = try unwrap(await stand.machine.prompts().first)
        XCTAssertEqual(prompt.kind, .recordThisMeeting, "оснастка: вид спроса")
        XCTAssertNil(
            prompt.expiresAt,
            "то же `nil`, что и у `.whichMeeting`, по той же причине класса, а не отдельным совпадением"
        )
        await stand.machine.stop()
    }
}
