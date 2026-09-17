//  Питание и сон при записи — К67 (инвариант 19) и К69 (§9.3, `willSleep`).
//  MEE-300, часть B. Пункты плана MEE-288 §3, раздел И, часть 5/8.
//
//  Файл отделён от `SessionMachineStopTests` по одному доводу и он механический: линт
//  считает тело типа длиннее двухсот пятидесяти строк нарушением. Предмет не делится —
//  делится текст.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachinePowerTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    /// Стенд, доведённый до `recording`, — тот же, что у `SessionMachineStopTests`.
    private func recording() async throws -> (SessionMachineBench, MeetingEvent, UUID) {
        let stand = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: .auto),
            weights: try SessionMachineFixtures.weights()
        )
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "оснастка: сессия в записи")
        return (stand, event, try XCTUnwrap(live.recordingId))
    }

    // MARK: - К67 (инв. 19) и К69 (§9.3, `willSleep`)

    /// Ровно один токен `reason == .recording` на всё время `recording` и `stopping`, и ни
    /// одного после выхода из множества — ПО КАЖДОМУ из трёх путей, включая строку 11.
    func test_k67_thePowerTokenIsHeldThroughoutAndReleasedOnEveryExitPath() async throws {
        // Путь 10 → 12.
        let (viaProcessing, event, recordingId) = try await recording()
        assertOneRecordingToken(viaProcessing, "путь 10 → 12, в `recording`")
        viaProcessing.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        try await viaProcessing.machine.stopRecording(
            recordingId: recordingId, now: moment.addingTimeInterval(70)
        )
        assertOneRecordingToken(viaProcessing, "путь 10 → 12, в `stopping`")
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: event.id)
        await viaProcessing.deliver(CaptureEvent.stopped(manifest))
        await viaProcessing.machine.tick(now: moment.addingTimeInterval(80))
        assertNoTokensLeft(viaProcessing, "путь 10 → 12")
        await viaProcessing.machine.stop()

        // Путь 10 → 13.
        let (viaStopFailure, _, secondId) = try await recording()
        viaStopFailure.capture.failStop(with: .notRunning)
        try await viaStopFailure.machine.stopRecording(
            recordingId: secondId, now: moment.addingTimeInterval(70)
        )
        assertNoTokensLeft(viaStopFailure, "путь 10 → 13")
        await viaStopFailure.machine.stop()

        // Путь строки 11 — различающий: реализация, отпускающая токен «при выходе из
        // `stopping`», течёт ровно здесь, и Mac остаётся не спящим после отказа захвата.
        let (viaRow11, _, _) = try await recording()
        await viaRow11.deliver(CaptureEvent.failed(.systemUnavailable(message: "отказ")))
        await viaRow11.machine.tick(now: moment.addingTimeInterval(80))
        assertNoTokensLeft(viaRow11, "путь строки 11")
        await viaRow11.machine.stop()
    }

    /// `willSleep` записи не останавливает: состояние не меняется, токен не отпускается,
    /// `stop()` захвата не зовётся. Проверяется в обоих состояниях множества.
    func test_k69_willSleepStopsNothingInEitherCapturingState() async throws {
        let (inRecording, _, recordingId) = try await recording()
        await inRecording.deliver(PowerEvent.willSleep)
        await inRecording.machine.tick(now: moment.addingTimeInterval(80))
        let stillRecording = try unwrap(await inRecording.machine.sessions().first)
        XCTAssertEqual(stillRecording.state, .recording)
        assertOneRecordingToken(inRecording, "`willSleep` в `recording`")
        XCTAssertEqual(
            inRecording.capture.callCount(of: { if case .stop = $0 { return true }; return false }), 0,
            "`stop()` захвата не зван"
        )

        inRecording.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        try await inRecording.machine.stopRecording(
            recordingId: recordingId, now: moment.addingTimeInterval(90)
        )
        await inRecording.deliver(PowerEvent.willSleep)
        await inRecording.machine.tick(now: moment.addingTimeInterval(100))
        let stillStopping = try unwrap(await inRecording.machine.sessions().first)
        XCTAssertEqual(stillStopping.state, .stopping, "`willSleep` в `stopping` ничего не меняет")
        assertOneRecordingToken(inRecording, "`willSleep` в `stopping`")
        await inRecording.machine.stop()
    }

    private func assertOneRecordingToken(_ stand: SessionMachineBench, _ label: String) {
        XCTAssertEqual(stand.power.liveActivities.count, 1, "\(label): токен ровно один")
        XCTAssertEqual(stand.power.liveActivities.first?.reason, .recording, "\(label): и его причина")
    }

    private func assertNoTokensLeft(_ stand: SessionMachineBench, _ label: String) {
        XCTAssertTrue(stand.power.liveActivities.isEmpty, "\(label): после выхода не держится ни один")
        XCTAssertEqual(
            stand.power.beginActivityCallCount, stand.power.endActivityCallCount,
            "\(label): взятых и отпущенных поровну"
        )
    }
}
