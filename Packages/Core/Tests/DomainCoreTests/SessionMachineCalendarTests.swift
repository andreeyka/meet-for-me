//  Календарь в состояниях записи и «Поведение» — К76 (§9.2) и К85.
//  MEE-300, часть B. Пункты плана MEE-288 §3, разделы К и Н, части 5/8 и 6/8.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineCalendarTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К76 (§9.2, четыре правила)

    /// (i) событие сдвинулось вперёд так, что `now < armAt` нового окна → `scheduled`
    /// (строка 5); (ii) сдвинулось назад, новый `graceEndsAt` ещё не прошёл → сроки
    /// пересчитываются НА МЕСТЕ; (iii) сдвинулось назад, новый `graceEndsAt` уже прошёл →
    /// `skipped` (строка 3).
    func test_k76_shiftsForwardAndBackwardAreAnsweredByTheirOwnRows() async throws {
        // (i) вперёд.
        let forward = try bench()
        let event = try SessionMachineFixtures.event()
        forward.seed(event)
        await forward.machine.start(now: moment.addingTimeInterval(-300))
        await forward.machine.tick(now: moment.addingTimeInterval(-300))
        let armed = try unwrap(await forward.machine.sessions().first)
        XCTAssertEqual(armed.state, .armed, "оснастка: сессия взведена")
        let later = try SessionMachineFixtures.event(
            id: event.id, start: moment.addingTimeInterval(3600)
        )
        await forward.deliver(CalendarChange.upserted([later]))
        await forward.machine.tick(now: moment.addingTimeInterval(-290))
        let returned = try unwrap(await forward.machine.sessions().first)
        XCTAssertEqual(returned.state, .scheduled, "(i) сессия вернулась строкой 5")
        XCTAssertEqual(returned.sessionId, armed.sessionId, "и не пересоздана (К7)")
        await forward.machine.stop()

        // (ii) назад, новый `graceEndsAt` ещё не прошёл.
        let back = try bench()
        let second = try SessionMachineFixtures.event()
        back.seed(second)
        await back.machine.start(now: moment.addingTimeInterval(-300))
        await back.machine.tick(now: moment.addingTimeInterval(-300))
        let shifted = try SessionMachineFixtures.event(
            id: second.id, start: moment.addingTimeInterval(-600)
        )
        await back.deliver(CalendarChange.upserted([shifted]))
        await back.machine.tick(now: moment.addingTimeInterval(-290))
        let inPlace = try unwrap(await back.machine.sessions().first)
        XCTAssertEqual(inPlace.state, .awaitingSignal, "(ii) сроки пересчитаны на месте")
        await back.machine.stop()

        // (iii) назад, новый `graceEndsAt` уже прошёл.
        let far = try bench()
        let third = try SessionMachineFixtures.event(start: moment.addingTimeInterval(1800))
        far.seed(third)
        await far.machine.start(now: moment.addingTimeInterval(900))
        await far.machine.tick(now: moment.addingTimeInterval(900))
        let past = try SessionMachineFixtures.event(
            id: third.id, start: moment.addingTimeInterval(-7200)
        )
        await far.deliver(CalendarChange.upserted([past]))
        await far.machine.tick(now: moment.addingTimeInterval(910))
        let alive = await far.machine.sessions()
        XCTAssertTrue(alive.isEmpty, "(iii) сессия ушла в `skipped`")
        XCTAssertEqual(far.meetings.storedRecords.first?.status, .skipped)
        await far.machine.stop()
    }

    /// (iv) ни изменение окна, ни отмена, ни удаление НЕ ТРОГАЮТ сессию в `recording`,
    /// `stopping` и `processing`: запись уже идёт, и календарь о ней ничего не знает.
    /// Реализация, уводящая такую сессию в `skipped`, обрывает созвон, который в эту минуту
    /// звучит, и зелена на всех трёх векторах выше.
    func test_k76_cancellationAndDeletionLeaveCapturingSessionsAlone() async throws {
        for state in [MeetingStatus.recording, .stopping, .processing] {
            for isDeletion in [false, true] {
                let stand = try bench()
                let event = try SessionMachineFixtures.event()
                stand.seed(event)
                stand.allowCaptureStart()
                stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
                await stand.machine.start(now: moment.addingTimeInterval(60))
                await stand.machine.tick(now: moment.addingTimeInterval(60))
                await stand.deliver(SessionMachineFixtures.audioOutput(
                    appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
                ))
                await stand.machine.tick(now: moment.addingTimeInterval(60))
                let live = try unwrap(await stand.machine.sessions().first)
                let recordingId = try XCTUnwrap(live.recordingId)

                if state != .recording {
                    try await stand.machine.stopRecording(
                        recordingId: recordingId, now: moment.addingTimeInterval(70)
                    )
                }
                if state == .processing {
                    let manifest = try SessionMachineFixtures.manifest(
                        recordingId: recordingId, meetingId: event.id
                    )
                    await stand.deliver(CaptureEvent.stopped(manifest))
                    await stand.machine.tick(now: moment.addingTimeInterval(80))
                }

                if isDeletion {
                    await stand.deliver(CalendarChange.deleted([event.id]))
                } else {
                    let cancelled = try SessionMachineFixtures.event(id: event.id, isCancelled: true)
                    await stand.deliver(CalendarChange.upserted([cancelled]))
                }
                await stand.machine.tick(now: moment.addingTimeInterval(90))

                let after = try unwrap(await stand.machine.sessions().first)
                XCTAssertEqual(after.state, state, "\(state), удаление \(isDeletion): сессия не тронута")
                await stand.machine.stop()
            }
        }
    }

    // MARK: - К85 («Поведение»)

    /// (i) `stop()` снимает подписки и идущую запись НЕ останавливает: `stop()` захвата не
    /// зовётся, токен не отпускается, состояние `recording` сохраняется. Оборванная запись
    /// подбирается §10 через `recover` — и потому останавливать её здесь нечем.
    func test_k85_stopDetachesTheInputsAndLeavesTheRecordingRunning() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(60))

        await stand.machine.stop()
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "состояние сохранено")
        XCTAssertEqual(
            stand.capture.callCount(of: { if case .stop = $0 { return true }; return false }), 0,
            "`stop()` захвата не зван ни разу"
        )
        XCTAssertEqual(stand.power.liveActivities.count, 1, "токен не отпущен")
    }

    /// (ii) отказы входов сессий НЕ РОНЯЮТ: сигналов просто нет, и сессия уходит в `skipped`
    /// своим сроком §8.3 — не в `failed`. Машина при этом не зовёт ни одного метода входов,
    /// который вправе отказать: ни `startObserving()`, ни `sync(trigger:)`.
    func test_k85_inputFailuresNeverTurnASessionIntoAFailedOne() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.calendar.failSync(with: .protocolViolation(
            sourceId: CalendarSourceId(rawValue: "eventkit"), message: "нет прав"
        ), for: CalendarSourceId(rawValue: "eventkit"))

        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(1200))

        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped, "`skipped`, а не `failed`")
        XCTAssertEqual(
            stand.processes.startObservingCallCount, 0,
            "бросающих методов входов машина не зовёт: подписка идёт потоком"
        )
        XCTAssertEqual(stand.calendar.syncCallCount, 0, "и `sync` не зван ни разу")
        await stand.machine.stop()
    }

    /// (iii) машина НЕ УДАЛЯЕТ НИЧЕГО — ни файлов записи, ни строк хранилища, ни задач
    /// очереди: ноль вызовов удаления на всех путях, включая запись и обработку.
    func test_k85_theMachineDeletesNothingOnAnyPath() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let live = try unwrap(await stand.machine.sessions().first)
        let recordingId = try XCTUnwrap(live.recordingId)
        try await stand.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(70))
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: event.id)
        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.machine.tick(now: moment.addingTimeInterval(80))

        let deleting = stand.log.signatures.filter { $0.contains("delete") || $0.contains("cancel") }
        XCTAssertEqual(deleting, [], "ни одного удаляющего вызова за весь путь")
        XCTAssertTrue(stand.repositories.recordings.directoriesAskedToDelete.isEmpty)
        XCTAssertEqual(stand.queue.cancellations, [], "и ни одной отменённой задачи")
        await stand.machine.stop()
    }
}
