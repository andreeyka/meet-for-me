//  Порядок строк таблицы §7 — четыре недостающих пересечения К45 и пересечение издания v7.
//  MEE-307, часть C. Пункты плана MEE-288 §3, раздел Ж.
//
//  ЧЕТЫРЕ ИЗ СЕМИ ПЕРЕСЕЧЕНИЙ К45 НЕ ПОДАВАЛИСЬ ДЕРЕВОМ НИ ОДНИМ ВЕКТОРОМ: (vi) 4/5,
//  (vii) 5/6, (viii) 12/13 и (ix) 14/15. Части A и B подали (i), (ii), (iii), (iv) и (v);
//  недостающие четыре и пересечение «команда при `.auto`/`.ask` против строки 1в»,
//  заведённое дельтой `Щ`, закрываются здесь. Последнее подаёт
//  `SessionMachineAdHocRuleTests.test_k95_bPrime_aCommandBeforeTheFirstTickBeatsRow1v`:
//  вход у него один и тот же, и дублировать его вторым вектором значило бы завести второе
//  место для одного утверждения.
//
//  ДОРОЖЕ ПРОЧИХ — (vii), И ЭТО СКАЗАНО САМИМ ПУНКТОМ: там расходятся «вернуться в
//  `scheduled`» и «начать запись», и реализация, проверяющая цель прежде календаря, НАЧНЁТ
//  ПИСАТЬ ВСТРЕЧУ, КОТОРАЯ УЕХАЛА. Ни один другой пункт перечня этого не ловит.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineRowOrderTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К45 (vi): строки 4 и 5 — побеждает 4

    /// `armed`, команда `skip` и одновременно `CalendarChange`, сдвинувший событие вперёд за
    /// `armAt` нового окна. Истинны строки 4 (`armed → skipped`) и 5 (`armed → scheduled`);
    /// побеждает строка с МЕНЬШИМ номером — 4, и сессия уходит в `skipped`.
    func test_k45_vi_row4BeatsRow5WhenBothAreTrue() async throws {
        let stand = try bench()
        let settings = SessionMachineFixtures.settings()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        await stand.machine.start(now: moment.addingTimeInterval(-60))
        await stand.machine.tick(now: moment.addingTimeInterval(-60))
        let armed = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(armed.state, .armed, "оснастка: сессия взведена")

        // Событие уехало так, что `now` меньше `armAt` НОВОГО окна: строка 5 истинна.
        let moved = try SessionMachineFixtures.event(
            id: event.id, start: moment.addingTimeInterval(3600)
        )
        XCTAssertLessThan(
            moment.addingTimeInterval(-60),
            SessionMachineRules.arm(for: moved, settings: settings).armAt,
            "оснастка: `now < armAt` нового окна — строка 5 истинна"
        )
        await stand.deliver(CalendarChange.upserted([moved]))
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(-60))

        let after = await stand.machine.session(id: armed.sessionId)
        XCTAssertEqual(after?.state, .skipped, "строка 4 победила строку 5")
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped)
        await stand.machine.tick(now: moment.addingTimeInterval(-59))
        let still = await stand.machine.session(id: armed.sessionId)
        XCTAssertEqual(still?.state, .skipped, "и ближайший `tick` её не оживляет (инвариант 3)")
        await stand.machine.stop()
    }

    // MARK: - К45 (vii): строки 5 и 6 — побеждает 5. ДОРОЖЕ ПРОЧИХ

    /// `armed`, событие сдвинулось вперёд (`now < armAt` нового окна) и ОДНОВРЕМЕННО есть
    /// свободная звучащая цель, отдаваемая политикой. Истинны строки 5 и 6; побеждает 5, и
    /// сессия возвращается в `scheduled`, А НЕ НАЧИНАЕТ ПИСАТЬ.
    ///
    /// Реализация, проверяющая цель прежде календаря, начнёт писать встречу, которая
    /// уехала: `CaptureRequest` уйдёт наружу, и запись пойдёт на созвон, которого в этом
    /// окне уже нет.
    func test_k45_vii_row5BeatsRow6AndTheMovedMeetingIsNotRecorded() async throws {
        let stand = try bench()
        stand.allowCaptureStart()
        let settings = SessionMachineFixtures.settings()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        let now = moment.addingTimeInterval(-60)
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        let armedProbe = await stand.machine.sessions()
        XCTAssertEqual(armedProbe.first?.state, .armed, "оснастка: взведена")

        // Обе клаузы истинны разом: цель свободна и отдаётся политикой `.auto`, а событие
        // уехало за `armAt` нового окна.
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: now, provider: "zoom"
        ))
        let moved = try SessionMachineFixtures.event(
            id: event.id, start: moment.addingTimeInterval(3600)
        )
        XCTAssertLessThan(
            now, SessionMachineRules.arm(for: moved, settings: settings).armAt,
            "оснастка: `now < armAt` нового окна"
        )
        await stand.deliver(CalendarChange.upserted([moved]))
        await stand.machine.tick(now: now)

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .scheduled, "строка 5 победила строку 6")
        XCTAssertNil(live.recordingId, "`recordingId` не назначен")
        XCTAssertEqual(
            stand.log.count(port: "AudioCapturePort", method: "start(_:)"), 0,
            "`CaptureRequest` наружу не ушёл ни разу: встречу, которая уехала, машина не пишет"
        )
        await stand.machine.stop()
    }

    /// Та же пара на чистой функции: при истинных обеих клаузах `deadlineRow` отдаёт
    /// строку 5, и это проверяется отдельно от хода машины.
    func test_k45_vii_theRuleItselfPrefersRow5() throws {
        let settings = SessionMachineFixtures.settings()
        let moved = try SessionMachineFixtures.event(start: moment.addingTimeInterval(3600))
        let input = SessionMachineRules.DeadlineInput(
            state: .armed,
            deadlines: SessionMachineRules.arm(for: moved, settings: settings),
            eventGone: false,
            gate: SessionMachineRules.RecordingGate(
                hasTarget: true, isTargetTaken: false, isAllowedByPolicy: true
            ),
            silenceStopsAt: nil
        )
        XCTAssertEqual(
            SessionMachineRules.deadlineRow(input, now: moment),
            .row5ArmedToScheduled,
            "при истинных строках 5 и 6 побеждает строка с меньшим номером"
        )
    }

    // MARK: - К45 (viii): строки 12 и 13 — побеждает 12

    /// `stopping`, в ОДИН `tick` получены `CaptureEvent.stopped(manifest)` (запись
    /// сохранена) и `CaptureEvent.failed(_)`. Истинны строки 12 и 13; побеждает 12, и
    /// сессия уходит в `processing`, а не в `failed`.
    func test_k45_viii_row12BeatsRow13WhenBothArriveInOneTick() async throws {
        let staged = try await standInStopping()
        let stand = staged.stand
        let manifest = try SessionMachineFixtures.manifest(
            recordingId: staged.recordingId, meetingId: staged.meetingId
        )

        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.deliver(CaptureEvent.failed(.systemUnavailable(message: "вектор")))
        await stand.machine.tick(now: moment.addingTimeInterval(120))

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .processing, "строка 12 победила строку 13")
        XCTAssertEqual(
            stand.repositories.recordings.storedRecords.first?.status, .finalized,
            "и запись сохранена — обе клаузы строки 12 обязательны"
        )
        await stand.machine.stop()
    }

    /// Обратный порядок прихода тех же двух событий ответа не меняет: порядок таблицы, а не
    /// порядок прихода.
    func test_k45_viii_theArrivalOrderOfTheTwoEventsDoesNotMatter() async throws {
        let staged = try await standInStopping()
        let stand = staged.stand
        let manifest = try SessionMachineFixtures.manifest(
            recordingId: staged.recordingId, meetingId: staged.meetingId
        )

        await stand.deliver(CaptureEvent.failed(.systemUnavailable(message: "вектор")))
        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.machine.tick(now: moment.addingTimeInterval(120))

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .processing, "ответ тот же: решает таблица, а не очередь")
        await stand.machine.stop()
    }

    // MARK: - К45 (ix): строки 14 и 15 — побеждает 14

    /// `processing`, в ОДИН `tick` получены `JobEvent.succeeded` задачи `attribute` этой
    /// записи и `JobEvent.cancelled` другой задачи цепочки. Истинны строки 14 и 15;
    /// побеждает 14, и сессия уходит в `ready`.
    ///
    /// РЕАЛИЗАЦИЯ, ЧИТАЮЩАЯ СОБЫТИЯ В ПОРЯДКЕ ПРИХОДА, ЗДЕСЬ КРАСНА: при `cancelled`,
    /// пришедшем первым, она отдаёт победу строке 15. Порядок таблицы решает, а не очередь.
    func test_k45_ix_row14BeatsRow15WhenBothArriveInOneTick() async throws {
        for cancelledFirst in [false, true] {
            let staged = try await standInProcessing()
            let stand = staged.stand
            let attribute = JobEvent.succeeded(jobId: staged.chainJobId, type: .attribute)
            let cancelled = JobEvent.cancelled(jobId: staged.chainJobId, type: .diarize)

            if cancelledFirst {
                await stand.deliver(cancelled)
                await stand.deliver(attribute)
            } else {
                await stand.deliver(attribute)
                await stand.deliver(cancelled)
            }
            await stand.machine.tick(now: moment.addingTimeInterval(300))

            let after = await stand.machine.session(id: staged.sessionId)
            XCTAssertEqual(
                after?.state, .ready,
                "cancelledFirst=\(cancelledFirst): строка 14 победила строку 15"
            )
            await stand.machine.stop()
        }
    }

    /// Та же пара со вторым видом отказа — `failed(willRetry: false)`.
    func test_k45_ix_row14BeatsRow15WithAPermanentFailureToo() async throws {
        let staged = try await standInProcessing()
        let stand = staged.stand
        await stand.deliver(JobEvent.failed(
            jobId: staged.chainJobId, type: .diarize, error: "вектор", willRetry: false
        ))
        await stand.deliver(JobEvent.succeeded(jobId: staged.chainJobId, type: .attribute))
        await stand.machine.tick(now: moment.addingTimeInterval(300))

        let after = await stand.machine.session(id: staged.sessionId)
        XCTAssertEqual(after?.state, .ready, "строка 14 побеждает и здесь")
        await stand.machine.stop()
    }

    // MARK: - Оснастка

    private struct StoppingStand {
        let stand: SessionMachineBench
        let recordingId: UUID
        let meetingId: UUID
        let sessionId: UUID
    }

    /// Сессия события, доведённая до `stopping` командой `stopRecording`.
    private func standInStopping() async throws -> StoppingStand {
        let stand = try bench()
        stand.allowCaptureStart()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        await stand.machine.start(now: moment.addingTimeInterval(-60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-60), provider: "zoom"
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(-60))
        let recording = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(recording.state, .recording, "оснастка: запись идёт")
        let recordingId = try unwrap(recording.recordingId)
        // `stop()` фейка без заданного манифеста бросает, а бросивший `stop()` есть
        // строка 13 — то есть оснастка увела бы сессию в `failed` мимо предмета.
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        try await stand.machine.stopRecording(recordingId: recordingId, now: moment)
        let stopping = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(stopping.state, .stopping, "оснастка: сессия останавливается")
        return StoppingStand(
            stand: stand, recordingId: recordingId,
            meetingId: event.id, sessionId: stopping.sessionId
        )
    }

    private struct ProcessingStand {
        let stand: SessionMachineBench
        let sessionId: UUID
        let chainJobId: UUID
    }

    /// Сессия события, доведённая до `processing` строкой 12, с известным номером задачи
    /// цепочки: только по НЕМУ машина и признаёт событие своим (К42).
    private func standInProcessing() async throws -> ProcessingStand {
        let chainJobId = UUID()
        let staged = try await standInStopping()
        let stand = staged.stand
        stand.queue.setNextSubmitIds([chainJobId])
        let manifest = try SessionMachineFixtures.manifest(
            recordingId: staged.recordingId, meetingId: staged.meetingId
        )
        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.machine.tick(now: moment.addingTimeInterval(120))
        let processing = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(processing.state, .processing, "оснастка: сессия обрабатывается")
        return ProcessingStand(
            stand: stand, sessionId: processing.sessionId, chainJobId: chainJobId
        )
    }
}
