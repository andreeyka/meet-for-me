//  Спрос у сессии, заведённой при уже прошедшем `askAt`, — К93.
//  MEE-307, часть C. Пункты плана MEE-288 §3, раздел Л, часть 5/8.
//
//  ПУНКТ ЗАКРЫВАЕТ ВХОД, КОТОРОГО У К51 НЕТ, И НЕ ПОДМЕНЯЕТ ЕГО. К51 стоит на общем
//  правиле — спрос поднимается В МОМЕНТ `askAt`; здесь подаётся сессия, которой в момент
//  `askAt` ещё не существовало, и ответ у неё другой: спрос поднимается В МОМЕНТ
//  ЗАВЕДЕНИЯ. Срок при этом НЕ «догоняется» задним числом и НЕ пропускается, и различает
//  эти два исхода `SessionPrompt.raisedAt`: он равен моменту заведения, а не `askAt`.
//
//  ТРИ ПУТИ, КОТОРЫМИ СОБЫТИЕ СТАНОВИТСЯ ИЗВЕСТНО ПОЗДНО, ПОДАЮТСЯ ПОРОЗНЬ — их называет
//  сам пункт: `CalendarChange`, принёсший новое событие; `tick(now:)` по хранилищу;
//  `start(now:)` (§10, перечень Б). Третий путь до части C подать было нечем.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineLateAskTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    /// Два момента заведения, названные пунктом: строка 1а (`askAt < now < e.start`) и
    /// строка 1б (`e.start ≤ now ≤ graceEndsAt`).
    private func openingMoments(for event: MeetingEvent) -> [(Date, MeetingStatus)] {
        let arm = SessionMachineRules.arm(
            for: event, settings: SessionMachineFixtures.settings(policy: .ask)
        )
        let askAt = arm.askAt ?? arm.startsAt
        return [
            (askAt.addingTimeInterval(1), .armed),
            (arm.startsAt.addingTimeInterval(60), .awaitingSignal)
        ]
    }

    // MARK: - К93, путь 1: `CalendarChange`, принёсший новое событие

    func test_k93_aCalendarChangeAfterAskAtRaisesThePromptAtOpening() async throws {
        let event = try SessionMachineFixtures.event()
        for (at, expected) in openingMoments(for: event) {
            let stand = try bench(policy: .ask)
            await stand.machine.start(now: at)
            await stand.deliver(CalendarChange.upserted([event]))
            await stand.machine.tick(now: at)

            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, expected, "заведена строкой своего отрезка")
            let prompt = try unwrap(await stand.machine.prompts().first)
            XCTAssertEqual(prompt.kind, .recordThisMeeting)
            XCTAssertEqual(prompt.sessionId, live.sessionId, "`sessionId` этой сессии")
            XCTAssertEqual(prompt.raisedAt, at, "`raisedAt` равен моменту ЗАВЕДЕНИЯ, а не `askAt`")
            await stand.machine.stop()
        }
    }

    // MARK: - К93, путь 2: `tick(now:)` по хранилищу

    func test_k93_aStoredMeetingReadByTickRaisesThePromptAtOpening() async throws {
        let event = try SessionMachineFixtures.event()
        for (at, expected) in openingMoments(for: event) {
            let stand = try bench(policy: .ask)
            stand.seed(event)
            await stand.machine.start(now: at)
            await stand.machine.tick(now: at)

            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, expected)
            let prompt = try unwrap(await stand.machine.prompts().first)
            XCTAssertEqual(prompt.raisedAt, at, "`raisedAt` равен моменту заведения")
            await stand.machine.stop()
        }
    }

    // MARK: - К93, путь 3: `start(now:)` — §10, перечень Б

    /// Третий путь до части C не подавался ничем: `start(now:)` сессий не восстанавливал.
    /// Встреча стоит в `armed` либо `awaitingSignal`, и спрос поднимается СРАЗУ, ещё до
    /// первого `tick` — иначе потребитель `changes()` увидел бы сессию без спроса, которого
    /// §8.2 ей обещает в момент заведения.
    func test_k93_startRaisesTheLatePromptBeforeTheFirstTick() async throws {
        let event = try SessionMachineFixtures.event()
        for (at, expected) in openingMoments(for: event) {
            let stand = try bench(policy: .ask)
            stand.seed(event, status: expected)
            await stand.machine.start(now: at)

            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, expected)
            let prompt = try unwrap(await stand.machine.prompts().first)
            XCTAssertEqual(prompt.raisedAt, at, "спрос поднят в момент заведения")
            XCTAssertEqual(
                stand.log.count(port: "AudioCapturePort", method: "start(_:)"), 0,
                "и ни одной записи при этом не начато"
            )
            await stand.machine.stop()
        }
    }

    // MARK: - К93, отрицательные

    /// При `.auto` и `.manual` спрос не поднимается НИ РАЗУ, и `askAt == nil` в
    /// `ScheduledArm` — та же подача, тот же момент, другой ответ (К50, К52, К70).
    func test_k93_negative_noPromptUnderAutoOrManual() async throws {
        let event = try SessionMachineFixtures.event()
        for policy in [AppSettings.RecordingPolicy.auto, .manual] {
            let arm = SessionMachineRules.arm(
                for: event, settings: SessionMachineFixtures.settings(policy: policy)
            )
            XCTAssertNil(arm.askAt, "\(policy): `askAt == nil`")

            let stand = try bench(policy: policy)
            stand.seed(event)
            let at = event.start.addingTimeInterval(60)
            await stand.machine.start(now: at)
            await stand.machine.tick(now: at)

            let prompts = await stand.machine.prompts()
            XCTAssertTrue(prompts.isEmpty, "\(policy): спрос не поднимается ни разу")
            await stand.machine.stop()
        }
    }

    /// Заведение ДО `askAt`: спрос поднимается в момент `askAt` по общему правилу (К51), а
    /// не в момент заведения. Это и есть граница между двумя пунктами, и она проверяется.
    func test_k93_negative_openingBeforeAskAtKeepsTheGeneralRule() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        let arm = SessionMachineRules.arm(
            for: event, settings: SessionMachineFixtures.settings(policy: .ask)
        )
        let askAt = try unwrap(arm.askAt)
        let early = askAt.addingTimeInterval(-30)

        await stand.machine.start(now: early)
        await stand.machine.tick(now: early)
        let beforeAsk = await stand.machine.prompts()
        XCTAssertTrue(beforeAsk.isEmpty, "до `askAt` спроса нет ни одного")

        await stand.machine.tick(now: askAt)
        let prompt = try unwrap(await stand.machine.prompts().first)
        XCTAssertEqual(prompt.raisedAt, askAt, "спрос поднят В МОМЕНТ `askAt`, а не заведения")
        await stand.machine.stop()
    }

    /// Сроки от момента заведения не зависят ни на секунду: `graceEndsAt` считается от
    /// `e.start` (К14), и сессия, заведённая поздно, уходит в `skipped` в СВОЙ срок, а не
    /// через `missingSignalGraceSeconds` после заведения.
    func test_k93_aLateSessionKeepsItsOwnGraceMeasuredFromEventStart() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        let arm = SessionMachineRules.arm(
            for: event, settings: SessionMachineFixtures.settings(policy: .ask)
        )
        let late = event.start.addingTimeInterval(60)

        await stand.machine.start(now: late)
        await stand.machine.tick(now: late)
        let opened = await stand.machine.sessions()
        XCTAssertEqual(opened.count, 1, "оснастка: заведена поздно")

        // Вектор непустоты: до своего срока сессия жива.
        await stand.machine.tick(now: arm.graceEndsAt.addingTimeInterval(-1))
        let alive = await stand.machine.sessions()
        XCTAssertEqual(alive.count, 1, "до своего срока сессия жива")

        // РАЗЛИЧАЮЩИЙ МОМЕНТ — САМ `graceEndsAt`, считанный от `e.start`. Реализация,
        // отсчитывающая grace от ЗАВЕДЕНИЯ, держала бы сессию ещё шестьдесят секунд — до
        // `late + missingSignalGraceSeconds`, — и здесь она красна.
        await stand.machine.tick(now: arm.graceEndsAt)
        let gone = await stand.machine.sessions()
        XCTAssertTrue(gone.isEmpty, "ушла в `skipped` в СВОЙ срок, считанный от `e.start`")
        await stand.machine.stop()
    }
}
