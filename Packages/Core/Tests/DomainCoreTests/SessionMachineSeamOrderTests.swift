//  ПЕРЕПРОВЕРКА ШВА A/B, часть вторая: порядок строк и наблюдаемость — К45, К46, К81, К86.
//  MEE-300, часть B, §4 постановки. Продолжение `SessionMachineSeamTests`.
//
//  Файл отделён от первого по одному доводу и он механический: `--strict` линта считает
//  файл длиннее четырёхсот строк нарушением. Предмет не делится — делится текст.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineSeamOrderTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    /// Проход до `ready` целиком — тот же, что в `SessionMachineSeamTests`; вынесен в
    /// оснастку `SessionMachineWholeWay`, чтобы два файла не держали двух его редакций.
    private func wholeWay() async throws -> SessionMachineWholeWay {
        try await SessionMachineWholeWay.build(from: moment)
    }

    // MARK: - К45 (инв. 2, порядок строк)

    /// (ii) `armed`, есть цель и `now ≥ e.start` — истинны строки 6 и 7, побеждает 6.
    /// Часть A этого вектора подать не могла: строки 6 у неё не было.
    func test_k45_ii_row6BeatsRow7WhenBothAreTrue() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        await stand.machine.start(now: moment.addingTimeInterval(-60))
        await stand.machine.tick(now: moment.addingTimeInterval(-60))
        let armedState = await stand.machine.sessions().first?.state
        XCTAssertEqual(armedState, .armed, "оснастка: взведена")

        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(30)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(30))
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "строка 6 победила строку 7")
        await stand.machine.stop()
    }

    /// (iii) `armed`, событие отменено и одновременно есть свободная цель — истинны строки 4
    /// и 6, побеждает 4.
    ///
    /// **Вектор пункта взят не дословно, и это названо строкой отчёта.** Пункт называет
    /// клаузой строки 4 «ответ `.skip` на спрос»; ответ `.skip` требует политики `.ask`, а
    /// строка 6 при `.ask` без ответа `.record` ложна клаузой политики (§8.2) — то есть
    /// дословный вектор под v5 неисполним, обе строки истинными не бывают. Взята другая
    /// клауза той же строки 4 — «событие отменено», — при которой обе строки истинны разом.
    func test_k45_iii_row4BeatsRow6WhenBothAreTrue() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        await stand.machine.start(now: moment.addingTimeInterval(-60))
        await stand.machine.tick(now: moment.addingTimeInterval(-60))

        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-50)
        ))
        let cancelled = try SessionMachineFixtures.event(id: event.id, isCancelled: true)
        await stand.deliver(CalendarChange.upserted([cancelled]))
        await stand.machine.tick(now: moment.addingTimeInterval(-50))

        let leftAfterRow4 = await stand.machine.sessions()
        XCTAssertTrue(leftAfterRow4.isEmpty, "строка 4 победила строку 6")
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped)
        XCTAssertEqual(stand.capture.recordedCalls.count, 0, "и захват не зван ни разу")
        await stand.machine.stop()
    }

    /// (iv) `recording`, одновременно условие §8.4 и `CaptureEvent.failed` — истинны строки
    /// 10 и 11, побеждает 10.
    ///
    /// **Наблюдается это ПОТОКОМ, а не конечным состоянием, и вот почему.** Победа строки 10
    /// уводит сессию в `stopping`; на том же ходу таблица читается заново, и там истинна
    /// строка 13 — тот же пришедший отказ, — так что неподвижная точка этого `tick` есть
    /// `failed`. Различает реализации ровно последовательность: победила строка 10 — в
    /// потоке есть снимок `stopping`; победила бы 11 — его не было бы вовсе.
    func test_k45_iv_row10BeatsRow11AndTheStreamShowsIt() async throws {
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
        let stream = stand.machine.changes()

        // Срок §8.4: 60 + 60 + 240 = 360. Отказ захвата приходит к тому же `tick`.
        await stand.deliver(CaptureEvent.failed(.systemUnavailable(message: "tap умер")))
        await stand.machine.tick(now: moment.addingTimeInterval(360))

        let changes = await collect(stream, count: 3)
        let states = changes.compactMap { $0.session?.state }
        XCTAssertEqual(states, [.recording, .stopping, .failed], "строка 10 прочитана прежде строки 11")
        await stand.machine.stop()
    }

    // MARK: - К46 (инв. 2, тотальность)

    /// Вид 1 перебора теперь накрывает и три состояния, которых у части A не было: вход, не
    /// названный ни одной строкой §7 для этого состояния, состояния НЕ МЕНЯЕТ и ошибки НЕ
    /// ДАЁТ, и в потоке не появляется ни одного лишнего снимка.
    func test_k46_kind1_unnamedInputsChangeNothingInTheCapturingStates() async throws {
        for state in [MeetingStatus.recording, .stopping, .processing] {
            let stage = try await standing(in: state)
            let stand = stage.stand
            let stream = stand.machine.changes()
            await stand.deliver(PowerEvent.willSleep)
            await stand.deliver(PowerEvent.screensDidSleep)
            await stand.deliver(CaptureEvent.levels(CaptureLevels(mic: 0.1, system: 0.2)))
            await stand.deliver(CaptureEvent.paused(atMs: 10))
            await stand.deliver(JobEvent.submitted(jobId: UUID(), type: .transcode))
            await stand.deliver(JobEvent.progressed(jobId: UUID(), fraction: 0.5))
            await stand.machine.tick(now: moment.addingTimeInterval(85))

            let after = try unwrap(await stand.machine.session(id: stage.sessionId))
            XCTAssertEqual(after.state, state, "\(state): состояние не изменилось")

            // Ни одного publish сверх снимка подписки: следующим в потоке идёт сторожевой
            // переход, и если бы неназванный вход что-то опубликовал, он встал бы перед ним.
            let sentinel = try await raiseSentinel(stage, from: state)
            let changes = await collect(stream, count: 2)
            XCTAssertEqual(
                changes.compactMap { $0.session?.state }, [state, sentinel],
                "\(state): между снимком подписки и сторожевым переходом нет ничего"
            )
            await stand.machine.stop()
        }
    }

    /// Сторожевой переход для каждого из трёх состояний: свой, потому что общей клаузы у них
    /// нет ни одной — `skip` из состояний записи не уводит никуда (строки нет).
    private func raiseSentinel(_ stage: Standing, from state: MeetingStatus) async throws -> MeetingStatus {
        switch state {
        case .recording:
            try await stage.stand.machine.stopRecording(
                recordingId: stage.recordingId, now: moment.addingTimeInterval(90)
            )
            return .stopping
        case .stopping:
            await stage.stand.deliver(CaptureEvent.failed(.notRunning))
            await stage.stand.machine.tick(now: moment.addingTimeInterval(90))
            return .failed
        default:
            await stage.stand.deliver(JobEvent.cancelled(jobId: stage.jobIds[0], type: .transcode))
            await stage.stand.machine.tick(now: moment.addingTimeInterval(90))
            return .failed
        }
    }

    // MARK: - К81 (инв. 18)

    /// `setStatus` вызван ПРЕЖДЕ публикации снимка — на каждом переходе, у которого источник
    /// и приёмник различаются, включая четыре новых: 8, 10, 12 и 14.
    func test_k81_setStatusPrecedesThePublishedSnapshotOnTheNewRowsToo() async throws {
        let way = try await wholeWay()
        let statuses = way.stand.log.calls(port: "MeetingRepository")
            .filter { $0.method == "setStatus(_:meetingId:)" }
            .compactMap { $0.arguments.first }
        XCTAssertEqual(
            statuses, ["recording", "stopping", "processing", "ready"],
            "запись исхода идёт на каждом переходе и в его порядке"
        )
        XCTAssertEqual(way.stand.meetings.storedRecords.first?.status, .ready)
        await way.stand.machine.stop()
    }

    // MARK: - К86 («Поведение», порядок фаз)

    /// Срок решается УЖЕ НА НОВОЙ ЦЕЛИ, пришедшей этим же `tick`: цель, доставленная между
    /// двумя `tick`, применяется в первой фазе, и строка 8 побеждает строку 9 в момент
    /// `graceEndsAt`. Часть A наблюдала это ослабленно — «сессия не ушла в `skipped`»; теперь
    /// наблюдается полный ответ — «ушла в `recording`».
    func test_k86_theDeadlineIsDecidedOnTheTargetThatArrivedInTheSameTick() async throws {
        let grace = moment.addingTimeInterval(1200)
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: grace.addingTimeInterval(-10)
        ))
        await stand.machine.tick(now: grace)

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "строка 8 решена на цели этого же `tick`")
        await stand.machine.stop()
    }

    // MARK: - Оснастка

    /// Стенд, доведённый до названного состояния, вместе с тем, чем его дальше двигать.
    private struct Standing {
        let stand: SessionMachineBench
        let sessionId: UUID
        let recordingId: UUID
        let jobIds: [UUID]
    }

    /// Сессия встречи, доведённая до названного состояния записи или обработки.
    private func standing(in state: MeetingStatus) async throws -> Standing {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        let ids = [UUID(), UUID(), UUID(), UUID()]
        stand.queue.setNextSubmitIds(ids)
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let live = try unwrap(await stand.machine.sessions().first)
        let recordingId = try XCTUnwrap(live.recordingId)
        let standing = Standing(
            stand: stand, sessionId: live.sessionId, recordingId: recordingId, jobIds: ids
        )
        guard state != .recording else { return standing }

        try await stand.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(70))
        guard state != .stopping else { return standing }

        let manifest = try SessionMachineFixtures.manifest(
            recordingId: recordingId, meetingId: live.meetingId
        )
        await stand.deliver(CaptureEvent.stopped(manifest))
        await stand.machine.tick(now: moment.addingTimeInterval(80))
        return standing
    }
}
