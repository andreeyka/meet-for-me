//  Ad-hoc созвон без события и строка 16 — К44, К60, К61.
//  MEE-300, часть B. Пункты плана MEE-288 §3, разделы Ж и З, части 3/8 и 4/8.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineAdHocTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    /// Стенд без единого события календаря: всякая цель здесь не отнесена ни к одной сессии
    /// (§5.4, правило 4) — то есть ровно вход §8.6.
    private func bench(policy: AppSettings.RecordingPolicy) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К60 (§8.6, ad-hoc)

    /// При `.auto` и `.ask` поднимается спрос с `sessionId` НОВОЙ сессии `origin == .adHoc`
    /// в состоянии `awaitingSignal` и `expiresAt == nil`; при `.manual` спрос не поднимается
    /// вовсе. `.auto` СПРАШИВАЕТ ТОЖЕ, и вектор подаёт все три политики именно потому, что
    /// читается это наоборот.
    func test_k60_adHocAsksUnderAutoAndAskAndNeverUnderManual() async throws {
        for policy in [AppSettings.RecordingPolicy.auto, .ask, .manual] {
            let stand = try bench(policy: policy)
            await stand.machine.start(now: moment)
            await stand.deliver(SessionMachineFixtures.audioOutput(
                appKey: "us.zoom.xos", observedAt: moment
            ))
            await stand.machine.tick(now: moment)

            let prompts = await stand.machine.prompts()
            if policy == .manual {
                XCTAssertTrue(prompts.isEmpty, "`.manual`: спрос не поднимается вовсе")
                let opened = await stand.machine.sessions()
                XCTAssertTrue(opened.isEmpty, "и сессии не заводится ни одной")
            } else {
                XCTAssertEqual(prompts.count, 1, "\(policy): спрос ровно один")
                XCTAssertEqual(prompts.first?.kind, .recordThisMeeting)
                XCTAssertNil(prompts.first?.expiresAt, "\(policy): `expiresAt == nil`")
                let session = try unwrap(await stand.machine.session(id: try XCTUnwrap(
                    prompts.first?.sessionId
                )))
                XCTAssertEqual(session.origin, .adHoc)
                XCTAssertNil(session.meetingId, "у ad-hoc `meetingId` равен `nil`")
                XCTAssertEqual(session.state, .awaitingSignal)
            }
            await stand.machine.stop()
        }
    }

    /// Ответ `.skip` уводит ad-hoc-сессию в `skipped`.
    func test_k60_aSkipAnswerEndsTheAdHocSession() async throws {
        let stand = try bench(policy: .auto)
        await stand.machine.start(now: moment)
        await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: moment))
        await stand.machine.tick(now: moment)

        let prompt = try unwrap(await stand.machine.prompts().first)
        try await stand.machine.answer(promptId: prompt.promptId, .skip, now: moment.addingTimeInterval(5))
        let session = try unwrap(await stand.machine.session(id: prompt.sessionId))
        XCTAssertEqual(session.state, .skipped)
        let leftAfterSkip = await stand.machine.prompts()
        XCTAssertTrue(leftAfterSkip.isEmpty, "спрос снят вместе с ответом")
        await stand.machine.stop()
    }

    // MARK: - К44 (строка 16: — → recording, ad-hoc)

    /// Оба условия строки 16 порознь — команда `startRecording(meetingId: nil)` и ответ
    /// `.record` на спрос §8.6.
    func test_k44_row16_firesOnTheCommandAndOnTheRecordAnswer() async throws {
        // Условие 1: команда. Политика `.manual` — спроса нет, и заводит сессию сама команда.
        let byCommand = try bench(policy: .manual)
        byCommand.allowCaptureStart()
        await byCommand.machine.start(now: moment)
        await byCommand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment
        ))
        await byCommand.machine.tick(now: moment)
        let recordingId = try await byCommand.machine.startRecording(meetingId: nil, now: moment)
        let commanded = try unwrap(await byCommand.machine.sessions().first)
        XCTAssertEqual(commanded.origin, .adHoc)
        XCTAssertNil(commanded.meetingId)
        XCTAssertEqual(commanded.state, .recording)
        XCTAssertEqual(commanded.recordingId, recordingId, "`recordingId` назначен и возвращён")
        await byCommand.machine.stop()

        // Условие 2: ответ `.record` на спрос §8.6.
        let byAnswer = try bench(policy: .auto)
        byAnswer.allowCaptureStart()
        await byAnswer.machine.start(now: moment)
        await byAnswer.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment
        ))
        await byAnswer.machine.tick(now: moment)
        let prompt = try unwrap(await byAnswer.machine.prompts().first)
        try await byAnswer.machine.answer(promptId: prompt.promptId, .record(sessionId: prompt.sessionId), now: moment)
        let answered = try unwrap(await byAnswer.machine.session(id: prompt.sessionId))
        XCTAssertEqual(answered.state, .recording, "ответ уводит в `recording` строкой 16")
        XCTAssertNotNil(answered.recordingId)
        let leftAfterRecord = await byAnswer.machine.prompts()
        XCTAssertTrue(leftAfterRecord.isEmpty, "и спрос снят")
        await byAnswer.machine.stop()
    }

    // MARK: - К61 (§8.6, спрос снимается сам)

    /// Цель перестала быть актуальной, ответа не было: спрос снимается САМ — в `changes()`
    /// приходит `promptWithdrawn`, `prompts()` его больше не отдаёт, — и сессия уходит в
    /// `skipped`. `expiresAt == nil` значит «держится, пока держится причина», а не «вечно»,
    /// и этот вектор — единственное место, где два чтения различаются.
    func test_k61_theAdHocPromptIsWithdrawnByItsCauseAndTheSessionIsSkipped() async throws {
        let stand = try bench(policy: .auto)
        let stream = stand.machine.changes()
        await stand.machine.start(now: moment)
        await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: moment))
        await stand.machine.tick(now: moment)
        let prompt = try unwrap(await stand.machine.prompts().first)

        // `signalTtlSeconds` оснастки — 60: к этой минуте цель уже не актуальна.
        await stand.machine.tick(now: moment.addingTimeInterval(120))

        let leftByCause = await stand.machine.prompts()
        XCTAssertTrue(leftByCause.isEmpty, "спрос снят сам")
        let session = try unwrap(await stand.machine.session(id: prompt.sessionId))
        XCTAssertEqual(session.state, .skipped, "и сессия ушла в `skipped`")

        let changes = await collect(stream, count: 4)
        XCTAssertTrue(
            changes.contains { $0.withdrawnPromptId == prompt.promptId },
            "в потоке пришёл `promptWithdrawn`"
        )
        await stand.machine.stop()
    }
}
