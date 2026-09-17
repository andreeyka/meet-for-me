//  Оснастка части B: сессия, доведённая до состояния записи либо обработки.
//  MEE-300, часть B.
//
//  ЗНАЧЕНИЕМ, А НЕ КОРТЕЖЕМ, И ЭТО НЕ ВКУС: линт считает кортеж длиннее двух элементов
//  нарушением (`large_tuple`), а стенду нужны четыре — стенд, событие, `sessionId` и
//  `recordingId`, — и пятым номера задач цепочки. Заодно снимается второе описание одного
//  и того же пути: три файла тестов вели сессию до `recording` каждый по-своему.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

/// Стенд, доведённый до названного состояния, вместе с тем, чем его двигать дальше.
struct SessionMachineStand {

    let stand: SessionMachineBench
    let event: MeetingEvent
    let sessionId: UUID
    let recordingId: UUID
    let jobIds: [UUID]

    /// Сессия встречи в `recording`: цель подана в `moment + 60`, запись начата строкой 8
    /// тем же `tick`.
    static func recording(from moment: Date) async throws -> SessionMachineStand {
        let stand = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: .auto),
            weights: try SessionMachineFixtures.weights()
        )
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        let ids = [UUID(), UUID(), UUID(), UUID()]
        stand.queue.setNextSubmitIds(ids)

        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "оснастка: сессия в записи")
        return SessionMachineStand(
            stand: stand,
            event: event,
            sessionId: live.sessionId,
            recordingId: try XCTUnwrap(live.recordingId),
            jobIds: ids
        )
    }

    /// Та же сессия, доведённая до `processing` строкой 12: команда `stopRecording`,
    /// затем `CaptureEvent.stopped(manifest)` с манифестом ЭТОЙ записи.
    static func processing(from moment: Date) async throws -> SessionMachineStand {
        let staged = try await recording(from: moment)
        staged.stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        try await staged.stand.machine.stopRecording(
            recordingId: staged.recordingId, now: moment.addingTimeInterval(70)
        )
        let manifest = try SessionMachineFixtures.manifest(
            recordingId: staged.recordingId, meetingId: staged.event.id
        )
        await staged.stand.deliver(CaptureEvent.stopped(manifest))
        await staged.stand.machine.tick(now: moment.addingTimeInterval(80))
        let live = try unwrap(await staged.stand.machine.session(id: staged.sessionId))
        XCTAssertEqual(live.state, .processing, "оснастка: сессия в обработке")
        return staged
    }
}
