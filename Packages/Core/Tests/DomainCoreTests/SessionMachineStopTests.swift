//  Остановка, отказ и питание — К38, К39, К40, К41, К56, К57, К58, К59, К67, К69.
//  MEE-300, часть B. Пункты плана MEE-288 §3, разделы Ж, З и И, части 3/8, 4/8 и 5/8.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineStopTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    /// Стенд, доведённый до `recording`, — оснастка `SessionMachineStand`.
    private func recording() async throws -> SessionMachineStand {
        try await SessionMachineStand.recording(from: moment)
    }

    // MARK: - К57 (§8.4, правило 2 — момент отсчёта)

    /// Отсчёт идёт от момента, в который цель ВЫПАЛА ИЗ СЛИЯНИЯ (`observedAt` последней
    /// актуальной цели плюс `signalTtlSeconds`), а НЕ от момента, когда машина это заметила.
    /// Задержка замечания подаётся ненулевой намеренно: при δ = 0 обе реализации отвечают
    /// одинаково, и вектор был бы зелен по построению.
    func test_k57_silenceIsCountedFromTheMomentTheTargetLeftTheMergeNotFromNoticing() async throws {
        let staged = try await recording()
        let stand = staged.stand

        let observed = moment.addingTimeInterval(60)
        let leftMerge = observed.addingTimeInterval(60)          // + signalTtlSeconds
        let stopsAt = leftMerge.addingTimeInterval(240)          // + silenceStopSeconds

        // Машина замечает пропажу с задержкой δ = 30 с.
        await stand.machine.tick(now: leftMerge.addingTimeInterval(30))
        let noticed = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(noticed.state, .recording, "замечено, но срок ещё не вышел")
        XCTAssertNil(noticed.target, "цель выпала из слияния")

        await stand.machine.tick(now: stopsAt.addingTimeInterval(-1))
        let waiting = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(waiting.state, .recording, "за секунду до срока — ещё запись")

        await stand.machine.tick(now: stopsAt)
        let stopped = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(stopped.state, .stopping, "в срок — и ни на δ позже")
        await stand.machine.stop()
    }

    /// Цель появилась снова до истечения срока: переход не наступает, отсчёт начинается заново.
    func test_k57_aReturnedTargetRestartsTheCountdown() async throws {
        let staged = try await recording()
        let stand = staged.stand

        let back = moment.addingTimeInterval(200)
        await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: back))
        await stand.machine.tick(now: back)

        // Прежний срок (60 + 60 + 240 = 360) проходит — и перехода нет.
        await stand.machine.tick(now: moment.addingTimeInterval(360))
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "отсчёт начался заново от нового `observedAt`")

        await stand.machine.tick(now: back.addingTimeInterval(300))
        let later = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(later.state, .stopping, "и кончился на 300 с позже нового момента")
        await stand.machine.stop()
    }

    // MARK: - К56 и К38 (§8.4, правило 1; строка 10)

    /// Конец окна события запись НЕ останавливает: `e.end` не стоит ни в одном условии
    /// строки 10. Вектор парен К38: один пункт проверяет, что условие полно, другой — что
    /// оно не шире, и зелёный одного без другого ничего не значит.
    func test_k56_theEndOfTheEventWindowStopsNothingWhileTheTargetIsActual() async throws {
        let staged = try await recording()
        let stand = staged.stand
        let event = staged.event

        for offset in [2000.0, 2100.0, 2200.0] {
            let now = moment.addingTimeInterval(offset)
            XCTAssertTrue(now > event.end, "вектор подаётся за концом окна")
            await stand.deliver(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: now))
            await stand.machine.tick(now: now)
            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, .recording, "на смещении \(offset) запись продолжается")
        }
        await stand.machine.stop()
    }

    /// Строка 10 срабатывает на каждом из двух условий порознь — срок §8.4 и команда.
    func test_k38_row10_firesOnBothOfItsConditionsSeparately() async throws {
        let staged = try await recording()
        let bySilence = staged.stand

        await bySilence.machine.tick(now: moment.addingTimeInterval(360))
        let silent = try unwrap(await bySilence.machine.sessions().first)
        XCTAssertEqual(silent.state, .stopping, "условие §8.4")
        await bySilence.machine.stop()

        let stagedSecond = try await recording()
        let byCommand = stagedSecond.stand
        let recordingId = stagedSecond.recordingId
        byCommand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        try await byCommand.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(70))
        let commanded = try unwrap(await byCommand.machine.sessions().first)
        XCTAssertEqual(commanded.state, .stopping, "команда `stopRecording`")
        await byCommand.machine.stop()
    }

    // MARK: - К58 (§8.4, правило 3; «команда сильнее политики и сильнее срока»)

    /// `stopRecording` переводит в `stopping` НЕМЕДЛЕННО, в момент вызова: снимок читается
    /// МЕЖДУ командой и следующим `tick`. Реализация, складывающая команды до `tick`, зелена
    /// на всяком другом векторе плана и красна ровно здесь.
    func test_k58_commandsActAtTheMomentOfTheCallNotOnTheNextTick() async throws {
        let staged = try await recording()
        let stand = staged.stand
        let recordingId = staged.recordingId
        stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        try await stand.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(70))
        let between = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(between.state, .stopping, "без единого `tick` после команды")
        await stand.machine.stop()

        // `startRecording` начинает запись при `.manual` и при висящем спросе.
        try await assertCommandBeatsPolicy(policy: .manual)
        try await assertCommandBeatsPolicy(policy: .ask)
    }

    private func assertCommandBeatsPolicy(policy: AppSettings.RecordingPolicy) async throws {
        let stand = SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
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
        let before = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(before.state, .awaitingSignal, "\(policy): сама машина не пишет")
        if policy == .ask {
            let pending = await stand.machine.prompts()
            XCTAssertFalse(pending.isEmpty, "и спрос висит")
        }

        _ = try await stand.machine.startRecording(meetingId: event.id, now: moment.addingTimeInterval(70))
        let after = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(after.state, .recording, "\(policy): команда сильнее политики")
        await stand.machine.stop()
    }

    // MARK: - К59 (§8.4, последний абзац; `systemSilent`)

    /// `systemSilent` условием строки 10 не является НИ ПРИ КАКИХ значениях полей: остановка
    /// по тишине в тапе выключила бы запись созвона, где говорит только пользователь.
    func test_k59_systemSilentNeverStopsTheRecording() async throws {
        let staged = try await recording()
        let stand = staged.stand

        for sinceMs in [0, 1, 1_000, 600_000] {
            await stand.deliver(CaptureEvent.systemSilent(sinceMs: sinceMs))
            await stand.deliver(SessionMachineFixtures.audioOutput(
                appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(100)
            ))
            await stand.machine.tick(now: moment.addingTimeInterval(100))
            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, .recording, "`systemSilent(\(sinceMs))` не останавливает")
        }
        // И при пропавшей цели остановку решает срок §8.4, а не тишина в тапе.
        await stand.deliver(CaptureEvent.systemSilent(sinceMs: 5_000))
        await stand.machine.tick(now: moment.addingTimeInterval(120))
        let stillRecording = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(stillRecording.state, .recording)
        await stand.machine.stop()
    }

    // MARK: - К39 (строка 11: recording → failed, минуя stopping)

    /// Сессия уходит в `failed` МИНУЯ `stopping`, и конечным состоянием это неотличимо от
    /// прохода через него — различает только последовательность потока.
    func test_k39_row11_goesToFailedWithoutPassingThroughStopping() async throws {
        let staged = try await recording()
        let stand = staged.stand
        let recordingId = staged.recordingId
        let stream = stand.machine.changes()
        await stand.deliver(CaptureEvent.failed(.systemUnavailable(message: "tap умер")))
        await stand.machine.tick(now: moment.addingTimeInterval(80))

        let changes = await collect(stream, count: 2)
        let states = changes.compactMap { $0.session?.state }
        XCTAssertEqual(states, [.recording, .failed], "между ними нет ни одного снимка `stopping`")
        let first = try XCTUnwrap(changes.first?.session)
        let last = try unwrap(await stand.machine.session(id: first.sessionId))
        XCTAssertEqual(last.recordingId, recordingId, "`recordingId` сохраняется (К3)")
        XCTAssertEqual(stand.capture.callCount(of: { if case .stop = $0 { return true }; return false }), 0,
                       "манифест не ожидается и `stop()` не зовётся")
        await stand.machine.stop()
    }

    // MARK: - К40 (строка 12: stopping → processing)

    /// Обе клаузы обязательны: получен `stopped(manifest)` И запись сохранена.
    func test_k40_row12_requiresBothTheManifestAndTheSavedRecord() async throws {
        let staged = try await recording()
        let ok = staged.stand
        let event = staged.event
        let recordingId = staged.recordingId
        ok.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        try await ok.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(70))
        let manifest = try SessionMachineFixtures.manifest(recordingId: recordingId, meetingId: event.id)
        await ok.deliver(CaptureEvent.stopped(manifest))
        await ok.machine.tick(now: moment.addingTimeInterval(80))

        let live = try unwrap(await ok.machine.sessions().first)
        XCTAssertEqual(live.state, .processing, "(а) обе клаузы истинны")
        XCTAssertEqual(ok.repositories.recordings.storedRecords.first?.status, .finalized)
        XCTAssertTrue(
            ok.log.happened("RecordingRepository.save(_:)", before: "JobQueue.submit(_:)"),
            "сохранение прежде постановки первой задачи"
        )
        XCTAssertEqual(ok.queue.submissions.count, 1, "и задача ровно одна")
        await ok.machine.stop()

        let stagedSecond = try await recording()
        let failing = stagedSecond.stand
        let secondEvent = stagedSecond.event
        let secondId = stagedSecond.recordingId
        failing.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        failing.repositories.recordings.fail(with: .io(message: "диск"), on: .save)
        try await failing.machine.stopRecording(recordingId: secondId, now: moment.addingTimeInterval(70))
        let second = try SessionMachineFixtures.manifest(recordingId: secondId, meetingId: secondEvent.id)
        await failing.deliver(CaptureEvent.stopped(second))
        await failing.machine.tick(now: moment.addingTimeInterval(80))

        let stuck = try unwrap(await failing.machine.sessions().first)
        XCTAssertEqual(stuck.state, .stopping, "(б) сохранение не состоялось — сессия осталась")
        XCTAssertEqual(failing.queue.submissions.count, 0, "и задача не поставлена ни одна")
        await failing.machine.stop()
    }

    // MARK: - К41 (строка 13: stopping → failed)

    /// Переход наступает на каждом из двух условий; задача цепочки при этом НЕ ставится.
    func test_k41_row13_firesOnBothConditionsAndSubmitsNothing() async throws {
        let staged = try await recording()
        let byThrow = staged.stand
        let recordingId = staged.recordingId
        byThrow.capture.failStop(with: .systemUnavailable(message: "остановить нечем"))
        try await byThrow.machine.stopRecording(recordingId: recordingId, now: moment.addingTimeInterval(70))
        // Сессия терминальна, и `sessions()` её уже не отдаёт: читается она по `id`.
        let failed = try unwrap(await byThrow.machine.session(id: staged.sessionId))
        XCTAssertEqual(failed.state, .failed, "`stop()` бросил")
        XCTAssertEqual(byThrow.queue.submissions.count, 0, "ноль `submit` за прогон")
        await byThrow.machine.stop()

        let stagedSecond = try await recording()
        let byEvent = stagedSecond.stand
        let secondId = stagedSecond.recordingId
        byEvent.capture.setStopManifest(RecordingManifestFixtures.unfinished)
        try await byEvent.machine.stopRecording(recordingId: secondId, now: moment.addingTimeInterval(70))
        await byEvent.deliver(CaptureEvent.failed(.directoryUnusable(message: "каталог")))
        await byEvent.machine.tick(now: moment.addingTimeInterval(80))
        let broken = try unwrap(await byEvent.machine.session(id: stagedSecond.sessionId))
        XCTAssertEqual(broken.state, .failed, "`CaptureEvent.failed` в `stopping`")
        XCTAssertEqual(byEvent.queue.submissions.count, 0)
        await byEvent.machine.stop()
    }
}
