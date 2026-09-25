//  Вход в запись — К34 (строка 6), К36 (строка 8), К47 и К48 (§7.1).
//  MEE-300, часть B. Пункты плана MEE-288 §3, разделы Ж и З, части 3/8 и 4/8. Правка
//  издания v8 контракта — MEE-341.
//
//  Форма всех четырёх одна: подаётся вход, на котором условие строки истинно целиком, —
//  переход обязан наступить; и вход, снимающий РОВНО ОДНУ клаузу, — переход обязан не
//  наступить. Клауз три, и снимаются они порознь: цели нет; цель занята чужой записью
//  (§7.1); политика цель не отдала (§8.2).
//
//  ОСНАСТКА «ЦЕЛЬ ЗАНЯТА» ВЫНЕСЕНА В `SessionMachineOccupiedTargetStaging.swift`: К48 и
//  К100 читают один и тот же вход разными файлами тестов (`docs/process.md` §5, «пара,
//  которую нельзя развести по разным прогонам»), а `--strict` линта не пустил бы её
//  вторую копию в файл длиннее четырёхсот строк.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineEntryTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    /// Сессия встречи, доведённая до `armed` (до `e.start`) либо до `awaitingSignal`.
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

    // MARK: - К34 (строка 6: armed → recording, ранний вход)

    /// Положительный вектор: все три клаузы истинны, вход подаётся СТРОГО ДО `e.start` —
    /// ранний вход §8.1 разрешён, и это не дефект.
    func test_k34_row6_firesBeforeEventStartWhenAllThreeClausesHold() async throws {
        let (stand, _) = try await standing(policy: .auto, at: -60)
        stand.allowCaptureStart()
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(-60))

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "строка 6 срабатывает до `e.start`")
        XCTAssertNotNil(live.recordingId, "`recordingId` назначен при входе в `recording`")
        XCTAssertEqual(live.target?.appKey, "us.zoom.xos")

        let request = try XCTUnwrap(startRequests(stand).first)
        XCTAssertEqual(request.recordingId, live.recordingId, "К3: поле запроса равно полю снимка")
        XCTAssertEqual(request.meetingId, live.meetingId)
        XCTAssertEqual(request.group?.appKey, "us.zoom.xos")
        await stand.machine.stop()
    }

    /// Два отрицательных вектора из трёх — «цели нет» и «политика запрещает». Третий,
    /// «цель занята», подан отдельным тестом ниже: его оснастка вдвое длиннее.
    func test_k34_row6_noTargetAndAClosedPolicyEachStopItAlone() async throws {
        let (noTarget, _) = try await standing(policy: .auto, at: -60)
        noTarget.allowCaptureStart()
        await noTarget.machine.tick(now: moment.addingTimeInterval(-60))
        let idle = try unwrap(await noTarget.machine.sessions().first)
        XCTAssertEqual(idle.state, .armed, "цели нет — строка 6 не срабатывает")
        await noTarget.machine.stop()

        let (manual, _) = try await standing(policy: .manual, at: -60)
        manual.allowCaptureStart()
        await manual.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-60)
        ))
        await manual.machine.tick(now: moment.addingTimeInterval(-60))
        let held = try unwrap(await manual.machine.sessions().first)
        XCTAssertEqual(held.state, .armed, "`.manual` — строка 6 не срабатывает")
        XCTAssertEqual(held.target?.appKey, "us.zoom.xos", "цель при этом есть")
        XCTAssertEqual(startRequests(manual).count, 0, "и захват не зван ни разу")
        await manual.machine.stop()
    }

    // MARK: - К36 (строка 8: awaitingSignal → recording)

    /// Условие строки 8 — ТО ЖЕ САМОЕ, что в строке 6, дословно. Один и тот же набор
    /// подаётся в оба состояния и требует одинакового ответа: два места, где написано одно
    /// условие, расходятся молча, и ловит это только парная подача.
    func test_k36_row8_answersExactlyAsRow6OnTheSameVectors() async throws {
        let vectors = [
            Row8Vector(policy: .auto, hasTarget: true, expected: .recording),
            Row8Vector(policy: .auto, hasTarget: false, expected: .awaitingSignal),
            Row8Vector(policy: .manual, hasTarget: true, expected: .awaitingSignal),
            Row8Vector(policy: .ask, hasTarget: true, expected: .awaitingSignal)
        ]
        for vector in vectors {
            let policy = vector.policy
            let hasTarget = vector.hasTarget
            let expected = vector.expected
            let (stand, _) = try await standing(policy: policy, at: 60)
            stand.allowCaptureStart()
            if hasTarget {
                await stand.deliver(SessionMachineFixtures.audioOutput(
                    appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(60)
                ))
            }
            await stand.machine.tick(now: moment.addingTimeInterval(60))
            let live = try unwrap(await stand.machine.sessions().first)
            XCTAssertEqual(live.state, expected, "политика \(policy), цель \(hasTarget)")
            await stand.machine.stop()
        }
    }

    // MARK: - К34 (в) и К47 (инв. 13; §7.1)

    /// Занятость читается по ОБОИМ состояниям множества — `recording` и `stopping`.
    /// Реализация, смотрящая только на `recording`, зелена на первой половине и красна на
    /// второй, а `stopping` держится ровно то окно, в которое второй созвон и начинается.
    func test_k47_oneGroupOneRecordingInBothCapturingStates() async throws {
        for stopHolder in [false, true] {
            let staged = try await SessionMachineOccupiedStand.withAdHocHolder(from: moment)
            let stand = staged.stand
            let event = staged.event
            let holder = staged.holder
            if stopHolder {
                stand.capture.setStopManifest(RecordingManifestFixtures.unfinished)
                let snapshot = try unwrap(await stand.machine.session(id: holder))
                try await stand.machine.stopRecording(
                    recordingId: try XCTUnwrap(snapshot.recordingId), now: moment.addingTimeInterval(20)
                )
                let stopping = try unwrap(await stand.machine.session(id: holder))
                XCTAssertEqual(stopping.state, .stopping, "держатель переведён в `stopping`")
            }
            await openWindowOfSecondSession(stand, at: moment)

            let owner = try unwrap(await stand.machine.sessions().first { $0.meetingId == event.id })
            XCTAssertEqual(owner.state, .armed, "вторая сессия не пишет: цель занята (§7.1)")
            XCTAssertEqual(owner.target?.appKey, "us.zoom.xos", "цель у неё при этом есть")
            let capturing = await stand.machine.sessions()
                .filter { $0.state == .recording || $0.state == .stopping }
            XCTAssertEqual(capturing.count, 1, "двух записей одной группы нет")
            XCTAssertEqual(startRequests(stand).count, 1, "второй `start` захвата не зван")
            await stand.machine.stop()
        }
    }

    // MARK: - К48 (§7.1, вторая половина; `SessionError.alreadyRecording`; издание v8)

    /// Команда, упёршаяся в занятую цель, бросает `alreadyRecording(sessionId:)`, и
    /// `sessionId` в ошибке — ТОЙ СЕССИИ, КОТОРАЯ ЗАНИМАЕТ ЦЕЛЬ, а не той, что просит:
    /// по этому полю фасад показывает человеку, какая встреча уже пишется. Вектор `armed`.
    func test_k48_commandThrowsAlreadyRecordingCarryingTheHolderSessionId() async throws {
        let staged = try await SessionMachineOccupiedStand.withAdHocHolder(from: moment)
        let stand = staged.stand
        let event = staged.event
        let holder = staged.holder

        // Ad-hoc: цель не отнесена ни к одной сессии, и она занята.
        await assertAlreadyRecording(
            stand: stand, meetingId: nil, holder: holder,
            at: moment.addingTimeInterval(10), label: "ad-hoc"
        )

        // Сессия с событием: её окно открыто, цель к ней отнесена и занята.
        await openWindowOfSecondSession(stand, at: moment)
        await assertAlreadyRecording(
            stand: stand, meetingId: event.id, holder: holder,
            at: moment.addingTimeInterval(3000), label: "сессия с событием"
        )
        await stand.machine.stop()
    }

    /// ПРАВКА ИЗДАНИЯ v8: занятость цели проверяется РАНЬШЕ состояния сессии и не уступает
    /// ему очередь ни на одном из четырёх состояний. `armed` уже подан тестом выше —
    /// здесь заведены три оставшихся, ранее не перечисленных по имени.
    ///
    /// РАЗЛИЧАЮЩИЙ ВЕКТОР — `scheduled`: команда читает сроки СВЕЖИМИ, в момент вызова, а
    /// не тем состоянием, в котором сессию оставил прошлый `tick` (§«Поведение»); строка не
    /// тикнута ни разу мимо `armAt`, состояние остаётся `.scheduled` и после команды, а
    /// `alreadyRecording` брошен всё равно — реализация, проверяющая состояние раньше
    /// занятости, ответила бы `nothingToRecord` (К100, тот же вход).
    func test_k48_targetOccupiedThrowsAlreadyRecordingInAwaitingSignalScheduledAndProcessing() async throws {
        let awaiting = try await SessionMachineOccupiedStand.awaitingOwner(from: moment)
        await assertAlreadyRecording(
            stand: awaiting.stand, meetingId: awaiting.event.id, holder: awaiting.holder,
            at: moment.addingTimeInterval(3600), label: "awaitingSignal"
        )
        await awaiting.stand.machine.stop()

        let scheduled = try await SessionMachineOccupiedStand.scheduledOwner(from: moment)
        await scheduled.stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(3000)
        ))
        await assertAlreadyRecording(
            stand: scheduled.stand, meetingId: scheduled.event.id, holder: scheduled.holder,
            at: moment.addingTimeInterval(3000), label: "scheduled"
        )
        let stillScheduled = try unwrap(
            await scheduled.stand.machine.sessions().first { $0.meetingId == scheduled.event.id }
        )
        XCTAssertEqual(
            stillScheduled.state, .scheduled,
            "различающий вектор: команда не тикает — состояние осталось `scheduled`"
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

    // MARK: - MEE-423 (IR-137, C-018 v11 инв. 25): откат на входе в `recording`

    /// Переход не записан — `capture.stop()` зван, `recordingDidStop()` зван (независимо от
    /// исхода `.stop()`), токен отпущен, `recordingId`/`target` сброшены в `store` (инвариант
    /// 5), и наружу идёт исходная ошибка перехода, а не какая-либо ещё.
    func test_mee423_enterRecordingRollsBackAndRethrowsOriginalTransitionErrorWhenWriteFails() async throws {
        let (stand, _) = try await standing(policy: .auto, at: -60)
        stand.allowCaptureStart()
        let failure = StorageError.io(message: "запись перехода не удалась")
        stand.meetings.fail(with: failure, on: .setStatus)
        let live = try unwrap(await stand.machine.sessions().first)
        let target = ProcessGroup(appKey: "us.zoom.xos", pids: [501], observedAt: moment.addingTimeInterval(-60))

        do {
            _ = try await stand.machine.enterRecording(
                live.sessionId, target: target, observedAt: moment.addingTimeInterval(-60),
                now: moment.addingTimeInterval(-60)
            )
            XCTFail("ожидался отказ записи перехода")
        } catch let error as StorageError {
            XCTAssertEqual(error, failure, "наружу — исходная ошибка перехода, не какая-либо ещё")
        }

        XCTAssertEqual(stand.queue.recordingDidStartCallCount, 1, "capture.start() удался — старт зван")
        XCTAssertEqual(stand.queue.recordingDidStopCallCount, 1, "откат зовёт recordingDidStop")
        XCTAssertEqual(
            stand.capture.callCount(of: { if case .stop = $0 { return true }; return false }), 1,
            "capture.stop() зван при откате"
        )
        XCTAssertTrue(stand.power.liveActivities.isEmpty, "токен отпущен при откате")
        XCTAssertEqual(
            stand.power.beginActivityCallCount, stand.power.endActivityCallCount, "взятых и отпущенных поровну"
        )

        let after = try unwrap(await stand.machine.session(id: live.sessionId))
        XCTAssertNil(after.recordingId, "инвариант 5: до `recording` `recordingId == nil`")
        XCTAssertNil(after.target, "цель сброшена вместе со входом")
        await stand.machine.stop()
    }

    /// `capture.stop()` вправе отказать сам при откате — это не меняет исход:
    /// `recordingDidStop()` зовётся всё равно, ровно один раз.
    func test_mee423_enterRecordingRollbackCallsRecordingDidStopEvenWhenCaptureStopFails() async throws {
        let (stand, _) = try await standing(policy: .auto, at: -60)
        stand.allowCaptureStart()
        stand.capture.failStop(with: .notRunning)
        stand.meetings.fail(with: .io(message: "запись перехода не удалась"), on: .setStatus)
        let live = try unwrap(await stand.machine.sessions().first)
        let target = ProcessGroup(appKey: "us.zoom.xos", pids: [501], observedAt: moment.addingTimeInterval(-60))

        do {
            _ = try await stand.machine.enterRecording(
                live.sessionId, target: target, observedAt: moment.addingTimeInterval(-60),
                now: moment.addingTimeInterval(-60)
            )
            XCTFail("ожидался отказ записи перехода")
        } catch {
            // ожидаемо — исходная ошибка перехода, проверена отдельным тестом выше.
        }

        XCTAssertEqual(
            stand.queue.recordingDidStopCallCount, 1, "вызван даже когда capture.stop() бросил"
        )
        await stand.machine.stop()
    }

    // MARK: - К102 (перечня MEE-277): отказ `capture.start()`

    /// `capture.start()` отказал — `recordingDidStart()` не зовётся ни разу: домен ещё не
    /// знает о начале записи, которой не случилось.
    func test_k102_captureStartFailureMeansRecordingDidStartIsNeverCalled() async throws {
        let (stand, _) = try await standing(policy: .auto, at: -60)
        stand.capture.failStart(with: .alreadyRunning)
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-60)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(-60))

        XCTAssertEqual(stand.queue.recordingDidStartCallCount, 0, "capture.start() отказал — старт не звался")
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .armed, "переход в `recording` не наступил")
        await stand.machine.stop()
    }

    // MARK: - Оснастка

    /// Вектор строки 8: политика, наличие цели и ожидаемое состояние. Значением, а не
    /// кортежем: линт считает кортеж длиннее двух элементов нарушением.
    private struct Row8Vector {
        let policy: AppSettings.RecordingPolicy
        let hasTarget: Bool
        let expected: MeetingStatus
    }

    private func startRequests(_ stand: SessionMachineBench) -> [CaptureRequest] {
        stand.capture.recordedCalls.compactMap { call -> CaptureRequest? in
            if case let .start(request) = call { return request }
            return nil
        }
    }
}
