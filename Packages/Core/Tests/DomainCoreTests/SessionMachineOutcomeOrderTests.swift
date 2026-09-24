//  К100 (§8.2, три исхода `startRecording(meetingId:)` и порядок между ними; издание v8).
//  MEE-341. Оснастка «цель занята» — `SessionMachineOccupiedTargetStaging.swift`, общая с
//  К48 (`docs/process.md` §5, «пара, которую нельзя развести по разным прогонам»).
//
//  ТРИ ИСХОДА И ПОРЯДОК МЕЖДУ НИМИ: (1) звучащей цели нет вовсе — `nothingToRecord`;
//  (2) цель есть и занята идущей записью другой сессии (§7.1) — `alreadyRecording
//  (sessionId:)`, ВНЕ ЗАВИСИМОСТИ от состояния, включая `scheduled` и `processing`;
//  (3) цель есть, свободна, а состояние не несёт строки 6 или 8 — `nothingToRecord`.
//  Занятость проверяется РАНЬШЕ состояния: вход «`scheduled`, цель занята» удовлетворяет
//  клаузам (2) и (3) разом, и побеждает (2) — реализация, проверяющая состояние раньше
//  занятости, ответила бы `nothingToRecord` вместо `alreadyRecording`.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineOutcomeOrderTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    /// Сессия встречи, доведённая до `armed` (до `e.start`) либо до `awaitingSignal`, без
    /// звучащей цели ни одной. Та же оснастка, что в `SessionMachineEntryTests` (К34).
    private func standing(
        policy: AppSettings.RecordingPolicy,
        at offset: TimeInterval
    ) async throws -> (SessionMachineBench, MeetingEvent) {
        let stand = try bench(policy: policy)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        await stand.machine.start(now: moment.addingTimeInterval(offset))
        await stand.machine.tick(now: moment.addingTimeInterval(offset))
        return (stand, event)
    }

    private func assertNothingToRecord(
        _ stand: SessionMachineBench, meetingId: UUID?, at now: Date, label: String
    ) async {
        do {
            _ = try await stand.machine.startRecording(meetingId: meetingId, now: now)
            XCTFail("\(label): обязан бросить `nothingToRecord`")
        } catch SessionError.nothingToRecord {
            // верно
        } catch {
            XCTFail("\(label): брошено не то: \(error)")
        }
    }

    // MARK: - Исход (1): звучащей цели нет вовсе

    /// Ни для сессии события (окно открыто, сигнала нет ни одного), ни для ad-hoc (живой
    /// цели нет ни одной).
    func test_k100_noSoundingTargetAnswersNothingToRecord() async throws {
        let (armed, event) = try await standing(policy: .auto, at: -60)
        await assertNothingToRecord(
            armed, meetingId: event.id, at: moment.addingTimeInterval(-60), label: "(1) событие без цели"
        )
        await armed.machine.stop()

        let noTarget = try bench(policy: .auto)
        await assertNothingToRecord(noTarget, meetingId: nil, at: moment, label: "(1) ad-hoc без цели")
        await noTarget.machine.stop()
    }

    // MARK: - Исход (2): цель занята — вне зависимости от состояния

    /// Во всех четырёх состояниях порознь, включая `scheduled` и `processing`, которым
    /// исход (3) полагал бы отказ по одной лишь клаузе состояния. Та же оснастка, что и
    /// К48 (`SessionMachineEntryTests`) — вход общий, а прогон свой.
    func test_k100_occupiedTargetAnswersAlreadyRecordingRegardlessOfState() async throws {
        let armed = try await SessionMachineOccupiedStand.armedOwner(from: moment)
        await assertAlreadyRecording(
            stand: armed.stand, meetingId: armed.event.id, holder: armed.holder,
            at: moment.addingTimeInterval(3000), label: "armed"
        )
        await armed.stand.machine.stop()

        let awaiting = try await SessionMachineOccupiedStand.awaitingOwner(from: moment)
        await assertAlreadyRecording(
            stand: awaiting.stand, meetingId: awaiting.event.id, holder: awaiting.holder,
            at: moment.addingTimeInterval(3600), label: "awaitingSignal"
        )
        await awaiting.stand.machine.stop()

        // Различающий вектор, общий с К48: `scheduled`, цель занята.
        let scheduled = try await SessionMachineOccupiedStand.scheduledOwner(from: moment)
        await scheduled.stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(3000)
        ))
        await assertAlreadyRecording(
            stand: scheduled.stand, meetingId: scheduled.event.id, holder: scheduled.holder,
            at: moment.addingTimeInterval(3000), label: "scheduled — различающий вектор с (3)"
        )
        await scheduled.stand.machine.stop()

        let processing = try await SessionMachineOccupiedStand.processingOwner(from: moment)
        await processing.stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-500)
        ))
        await assertAlreadyRecording(
            stand: processing.stand, meetingId: processing.event.id, holder: processing.holder,
            at: moment.addingTimeInterval(-500), label: "processing"
        )
        await processing.stand.machine.stop()
    }

    // MARK: - Исход (3): цель свободна, а состояние не несёт строки 6 или 8

    /// `scheduled` и `processing`. Вход «`scheduled`, цель СВОБОДНА» отличает этот исход от
    /// занятости различающим вектором выше: та же пара состояние/статус, другой ответ,
    /// потому что клауза занятости здесь ложна.
    func test_k100_freeTargetButWrongStateAnswersNothingToRecord() async throws {
        let scheduled = try bench(policy: .auto)
        let scheduledEvent = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
        scheduled.seed(scheduledEvent)
        await scheduled.machine.start(now: moment)
        await scheduled.machine.tick(now: moment)
        let stillScheduled = try unwrap(await scheduled.machine.sessions().first)
        XCTAssertEqual(stillScheduled.state, .scheduled, "оснастка: окно не открыто ни одним `tick`")
        await scheduled.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(3000)
        ))
        await assertNothingToRecord(
            scheduled, meetingId: scheduledEvent.id,
            at: moment.addingTimeInterval(3000), label: "(3) scheduled, цель свободна"
        )
        await scheduled.machine.stop()

        let processing = try await SessionMachineFreeTargetStand.processingOwner(from: moment)
        await processing.stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "owner.target", observedAt: moment.addingTimeInterval(-500)
        ))
        await assertNothingToRecord(
            processing.stand, meetingId: processing.event.id,
            at: moment.addingTimeInterval(-500), label: "(3) processing, цель свободна"
        )
        await processing.stand.machine.stop()
    }
}
