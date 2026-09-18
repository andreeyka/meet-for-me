//  Окончание спора без ответа и занятая цель — К98, К94, и правка К24 издания v7.
//  MEE-307, часть C. Пункты плана MEE-288 §3, раздел Д.
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

    /// Две сессии ОДНОГО провайдера с пересекающимися окнами: цель относится к обеим
    /// правилом 2. Ответ — обе живы, спор поднят.
    private func standWithTwoSessionsOfOneProvider(
        at now: Date,
        policy: AppSettings.RecordingPolicy = .auto
    ) throws -> (stand: SessionMachineBench, first: MeetingEvent, second: MeetingEvent) {
        let stand = try bench(policy: policy)
        let first = try SessionMachineFixtures.event(provider: "zoom")
        let second = try SessionMachineFixtures.event(
            start: moment.addingTimeInterval(300), provider: "zoom"
        )
        stand.seed(first)
        stand.seed(second)
        return (stand, first, second)
    }

    // MARK: - К24, правка издания v7: спор поднимается и при отнесении правилом 2

    /// ДВА ПЕРЕСЕКАЮЩИХСЯ СОЗВОНА ОДНОГО ПРОВАЙДЕРА СПРАШИВАЮТ ЧЕЛОВЕКА ВСЕГДА, и это цена,
    /// названная §5.4 прямо. До издания v7 этот вход спором не был: признак стоял на НОМЕРЕ
    /// правила, а правило 2 из определения выпадало, — и машина молча отдавала цель одной
    /// стороне, а вторая уходила в `skipped` по клаузе «цель занята».
    func test_k24_v7_twoOverlappingCallsOfOneProviderAlwaysAskTheHuman() async throws {
        let now = moment.addingTimeInterval(400)
        let staged = try standWithTwoSessionsOfOneProvider(at: now)
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
        let staged = try standWithTwoSessionsOfOneProvider(at: now)
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
        let staged = try standWithTwoSessionsOfOneProvider(at: now)
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
        let staged = try standWithTwoSessionsOfOneProvider(at: now)
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

    // MARK: - К94 (§7.1; строка 9, третья причина клаузы)

    /// Цель ЕСТЬ, актуальна, политика её ОТДАЁТ — и она ЗАНЯТА идущей записью другой
    /// сессии. Держателем выступает AD-HOC-СЕССИЯ, и это клауза Входа, а не деталь
    /// оснастки: две сессии событий одного провайдера дали бы не занятость, а СПОР, и
    /// `skipped` пришёл бы по ПЕРВОЙ причине клаузы, то есть мимо проверяемого входа.
    ///
    /// Ad-hoc-держатель спора не заводит, и довод — правило `1а` §5.4: оно стоит раньше
    /// правил 2 и 3, и сторон спора не прибавляет ни одной.
    func test_k94_aHeldTargetSendsTheSessionToSkippedByTheThirdCause() async throws {
        let settings = SessionMachineFixtures.settings()
        let stand = try bench(policy: .auto)
        stand.allowCaptureStart()
        let event = try SessionMachineFixtures.event(provider: "zoom")
        stand.seed(event)

        // ДЕРЖАТЕЛЬ ЗАВОДИТСЯ ДО `armAt` СОБЫТИЯ, И ЭТО ЧАСТЬ ВХОДА, А НЕ ОСНАСТКА: пока
        // окно закрыто, правило 2 к сессии события сигнала не относит, и тот есть вход
        // §8.6 (правило 4). Команда подаётся до первого `tick`, чтобы сессию завела
        // строка 16 без спроса (К44).
        let before = SessionMachineRules.arm(for: event, settings: settings)
            .armAt.addingTimeInterval(-100)
        await stand.machine.start(now: before)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: before, provider: "zoom"
        ))
        let holderRecording = try await stand.machine.startRecording(meetingId: nil, now: before)
        let holder = try unwrap(await stand.machine.sessions().first { $0.origin == .adHoc })
        XCTAssertEqual(holder.state, .recording, "оснастка: ad-hoc-держатель пишет")
        XCTAssertEqual(holder.recordingId, holderRecording)

        let grace = SessionMachineRules.arm(for: event, settings: settings).graceEndsAt
        // Цель подаётся ЗАНОВО перед каждым проверяемым моментом: иначе к `graceEndsAt` она
        // старше `signalTtlSeconds` и вход не подан вовсе (К51, К52).
        let earlier = grace.addingTimeInterval(-30)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: earlier, provider: "zoom"
        ))
        await stand.machine.tick(now: earlier)
        let waiting = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(waiting.state, .awaitingSignal, "до `graceEndsAt` стоит и ждёт")
        XCTAssertEqual(waiting.target?.appKey, "us.zoom.xos", "при ЗАПОЛНЕННОЙ и актуальной цели")

        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: grace, provider: "zoom"
        ))
        await stand.machine.tick(now: grace)

        let ofMeeting = await stand.machine.sessions().first { $0.meetingId == event.id }
        XCTAssertNil(ofMeeting, "в САМ момент `graceEndsAt` сессия ушла в `skipped` строкой 9")
        XCTAssertEqual(
            stand.meetings.storedRecords.first?.status, .skipped,
            "и хранимый `MeetingStatus` записан `setStatus`-ом (К81)"
        )
        let keeper = try unwrap(await stand.machine.sessions().first { $0.origin == .adHoc })
        XCTAssertEqual(keeper.state, .recording, "держатель при этом продолжает писать")
        XCTAssertEqual(keeper.recordingId, holderRecording, "его `recordingId` не меняется (К3)")
        XCTAssertEqual(keeper.target?.appKey, "us.zoom.xos", "и его цель остаётся заполненной")
        XCTAssertEqual(
            stand.log.count(port: "AudioCapturePort", method: "start(_:)"), 1,
            "`CaptureRequest` наружу не ушёл ни разу сверх записи держателя"
        )
        await stand.machine.stop()
    }

    /// Отрицательный (а): держатель выходит из множества `{recording, stopping}` ДО
    /// `graceEndsAt`, цель освобождается — сессия обязана уйти в `recording` СТРОКОЙ 8, а
    /// не в `skipped`.
    func test_k94_a_negative_aFreedTargetSendsTheSessionToRecordingByRow8() async throws {
        let settings = SessionMachineFixtures.settings()
        let stand = try bench(policy: .auto)
        stand.allowCaptureStart()
        let event = try SessionMachineFixtures.event(provider: "zoom")
        stand.seed(event)
        let arm = SessionMachineRules.arm(for: event, settings: settings)
        let before = arm.armAt.addingTimeInterval(-100)

        await stand.machine.start(now: before)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: before, provider: "zoom"
        ))
        _ = try await stand.machine.startRecording(meetingId: nil, now: before)
        let holder = await stand.machine.sessions().first { $0.origin == .adHoc }
        XCTAssertNotNil(holder, "оснастка: держатель пишет")

        // Держатель выходит из множества `{recording, stopping}` ДО `graceEndsAt`.
        await stand.deliver(CaptureEvent.failed(.systemUnavailable(message: "вектор")))
        let freeing = arm.startsAt.addingTimeInterval(30)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: freeing, provider: "zoom"
        ))
        await stand.machine.tick(now: freeing)

        let freed = await stand.machine.sessions().first { $0.origin == .adHoc }
        XCTAssertNil(freed, "оснастка: держатель вышел из множества `{recording, stopping}`")
        let ofMeeting = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(ofMeeting.state, .recording, "цель освободилась — строка 8, а не строка 9")
        await stand.machine.stop()
    }

    /// Отрицательный (б): держатель занимает ДРУГОЙ `appKey` — переход в `skipped` не
    /// наступает, и сессия уходит в `recording` своей целью.
    func test_k94_b_negative_aHolderOfAnotherAppKeyBlocksNothing() async throws {
        let settings = SessionMachineFixtures.settings()
        let stand = try bench(policy: .auto)
        stand.allowCaptureStart()
        let event = try SessionMachineFixtures.event(provider: "zoom")
        stand.seed(event)
        let arm = SessionMachineRules.arm(for: event, settings: settings)
        let before = arm.armAt.addingTimeInterval(-100)

        await stand.machine.start(now: before)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "com.microsoft.teams", observedAt: before, provider: nil
        ))
        _ = try await stand.machine.startRecording(meetingId: nil, now: before)

        let at = arm.startsAt.addingTimeInterval(30)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: at, provider: "zoom"
        ))
        await stand.machine.tick(now: at)

        let ofMeeting = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
        XCTAssertEqual(ofMeeting.state, .recording, "чужая занятость не мешает ни на сколько")
        await stand.machine.stop()
    }
}
