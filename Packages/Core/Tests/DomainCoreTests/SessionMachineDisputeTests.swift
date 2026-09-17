//  Спор о звучащей цели — К24 и К25. Продолжение `SessionMachineSignalTests`.
//  MEE-298, часть A. Пункты плана MEE-288 §3, раздел Д, часть 2/8.
//
//  Файл отделён от первого по механическому доводу: `--strict` линта считает файл длиннее
//  четырёхсот строк нарушением. Предмет не делится — делится текст.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineDisputeTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(
        weights: SignalWeights? = nil,
        policy: AppSettings.RecordingPolicy = .auto
    ) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try weights ?? SessionMachineFixtures.weights()
        )
    }

    // MARK: - К24 (§5.4, «спор, а не выбор»)

    /// Цель, отнесённая правилом 3 к двум сессиям сразу: ОДИН спрос `.whichMeeting`,
    /// кандидаты по возрастанию, `sessionId` спроса — первый из них; ответа нет — КАЖДАЯ
    /// уходит в `skipped` по СВОЕМУ `graceEndsAt`, а не по общему.
    func test_k24_aDisputeRaisesOneWhichMeetingPromptAndEachSideKeepsItsOwnGrace() async throws {
        let stand = try bench()
        let early = try SessionMachineFixtures.event(provider: nil)
        let late = try SessionMachineFixtures.event(start: moment.addingTimeInterval(300), provider: nil)
        stand.seed(early)
        stand.seed(late)

        let now = moment.addingTimeInterval(400)
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        let probe8 = await stand.machine.sessions().count
        XCTAssertEqual(probe8, 2, "обе сессии живы")

        stand.processes.emit(SessionMachineFixtures.audioOutput(appKey: "browser", observedAt: now, provider: nil))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: now)

        let prompts = await stand.machine.prompts()
        XCTAssertEqual(prompts.count, 1, "один спрос на спор, а не по одному на кандидата")
        let prompt = try XCTUnwrap(prompts.first)
        guard case let .whichMeeting(candidates) = prompt.kind else {
            return XCTFail("вид спроса — `.whichMeeting`")
        }
        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates, candidates.sorted { SessionMachineOrder.ascending($0, $1) }, "по возрастанию")
        XCTAssertEqual(prompt.sessionId, candidates[0], "`sessionId` — первый кандидат")
        XCTAssertNil(prompt.expiresAt)
        for session in await stand.machine.sessions() {
            XCTAssertNil(session.target, "до ответа спорная цель не принадлежит ни одной")
        }

        // Ответа нет: каждая уходит по СВОЕМУ сроку, а не по общему.
        await stand.machine.tick(now: moment.addingTimeInterval(1200))
        let afterFirstGrace = await stand.machine.sessions()
        XCTAssertEqual(afterFirstGrace.count, 1, "ушла та, чей `graceEndsAt` наступил")
        XCTAssertEqual(afterFirstGrace.first?.meetingId, late.id)

        await stand.machine.tick(now: moment.addingTimeInterval(1500))
        let probe9 = await stand.machine.sessions().isEmpty
        XCTAssertTrue(probe9, "и вторая — в свой срок")
        await stand.machine.stop()
    }

    // MARK: - К25 (§5.4, «правило 2 отнесло ровно к одной»)

    func test_k25_rule2SinglesOutOneSessionAndNoPromptIsRaised() async throws {
        let stand = try bench()
        let zoomMeeting = try SessionMachineFixtures.event(provider: "zoom")
        let meetMeeting = try SessionMachineFixtures.event(start: moment.addingTimeInterval(300), provider: "meet")
        stand.seed(zoomMeeting)
        stand.seed(meetMeeting)

        let now = moment.addingTimeInterval(400)
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        stand.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, provider: "zoom"))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: now)

        let probe10 = await stand.machine.prompts().isEmpty
        XCTAssertTrue(probe10, "спора нет: правило 2 отнесло цель к одной")
        let owner = await stand.machine.sessions().first { $0.meetingId == zoomMeeting.id }
        XCTAssertEqual(owner?.target?.appKey, "us.zoom.xos", "и она же держит цель")
        let stranger = await stand.machine.sessions().first { $0.meetingId == meetMeeting.id }
        XCTAssertNil(stranger?.target)
        await stand.machine.stop()
    }

    /// Вход-цена, названный контрактом: два пересекающихся созвона ОДНОГО провайдера
    /// спрашивают пользователя ВСЕГДА. Цена названа автором и «исправлению» не подлежит.
    func test_k25_twoOverlappingMeetingsOfOneProviderAlwaysAsk() async throws {
        let stand = try bench()
        let first = try SessionMachineFixtures.event(provider: "zoom")
        let second = try SessionMachineFixtures.event(start: moment.addingTimeInterval(300), provider: "zoom")
        stand.seed(first)
        stand.seed(second)

        let now = moment.addingTimeInterval(400)
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        stand.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, provider: "zoom"))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: now)

        let probe11 = await stand.machine.prompts().count
        XCTAssertEqual(probe11, 1, "правило 2 отнесло цель к обеим — спрос")
        await stand.machine.stop()
    }
}
