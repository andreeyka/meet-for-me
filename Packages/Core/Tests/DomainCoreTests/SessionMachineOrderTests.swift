//  Порядок строк, тотальность отображения и порядок фаз в один `tick` — К45, К46, К86.
//  MEE-298, часть A. Пункты плана MEE-288 §3, разделы Ж и Н, части 3/8 и 6/8.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineOrderTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    /// Состояние перебора и момент, в который оно достижимо. Тип, а не трёхчленный кортеж.
    private struct StateVector {
        let name: String
        let offset: TimeInterval
        let expected: MeetingStatus
    }

    private func bench(policy: AppSettings.RecordingPolicy = .auto) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К45 (инв. 2, первая половина: порядок строк)

    /// (i) `scheduled`, `now > graceEndsAt`: ПЕРЕСЕЧЕНИЯ БОЛЬШЕ НЕТ — строка 2 ложна верхней
    /// границей, истинна только строка 3. Проверяется именно то, что строка 2 не побеждает
    /// ПОТОМУ ЧТО ЛОЖНА, а не потому что уступила по порядку.
    func test_k45_i_row2IsFalsePastGraceSoRow3IsTheOnlyTrueOne() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let deadlines = SessionMachineRules.arm(for: event, settings: SessionMachineFixtures.settings())
        let past = deadlines.graceEndsAt.addingTimeInterval(1)
        let input = SessionMachineRules.DeadlineInput(
            state: .scheduled,
            deadlines: deadlines,
            eventGone: false,
            gate: .closed,
            silenceStopsAt: nil
        )
        XCTAssertEqual(
            SessionMachineRules.deadlineRow(input, now: past),
            .row3ScheduledToSkipped,
            "строка 2 на этом `now` ложна, и подходит только строка 3"
        )

        let stream = stand.machine.changes()
        await stand.machine.tick(now: moment.addingTimeInterval(-900))
        await stand.machine.tick(now: past)
        let changes = await collect(stream, count: 2)
        XCTAssertEqual(changes.compactMap { $0.session?.state }, [.scheduled, .skipped])
    }

    /// (v) Три заводящие строки взаимно исключают друг друга по `now`: это разбиение
    /// отрезка, и на каждом из трёх истинна ровно одна.
    func test_k45_v_theThreeOpeningRowsPartitionTheInterval() throws {
        let event = try SessionMachineFixtures.event()
        let settings = SessionMachineFixtures.settings()
        let deadlines = SessionMachineRules.arm(for: event, settings: settings)

        let probes: [(Date, MeetingStatus?)] = [
            (deadlines.armAt.addingTimeInterval(-1), .scheduled),
            (deadlines.armAt, .armed),
            (deadlines.startsAt.addingTimeInterval(-1), .armed),
            (deadlines.startsAt, .awaitingSignal),
            (deadlines.graceEndsAt, .awaitingSignal),
            (deadlines.graceEndsAt.addingTimeInterval(1), nil)
        ]
        for (probe, expected) in probes {
            XCTAssertEqual(
                SessionMachineRules.openingState(event: event, settings: settings, now: probe),
                expected,
                "на моменте \(probe.timeIntervalSince(deadlines.startsAt)) от начала события"
            )
        }
    }

    /// (iii) `armed`, ответ `.skip` и одновременно есть звучащая цель: побеждает строка с
    /// меньшим номером — 4. Строки 6, с которой здесь спор, в части A нет ни одной, и
    /// потому вектор проверяет ИСХОД, а не разрешение спора; названо строкой отчёта.
    func test_k45_iii_answerSkipWinsOverAPresentTarget() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        let now = moment.addingTimeInterval(-60)
        await stand.machine.start(now: now)
        await stand.machine.tick(now: now)
        stand.processes.emit(SessionMachineFixtures.audioOutput(appKey: "us.zoom.xos", observedAt: now))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: now)

        let probe0 = await stand.machine.sessions().first
        let live = try XCTUnwrap(probe0)
        XCTAssertEqual(live.state, .armed)
        XCTAssertEqual(live.target?.appKey, "us.zoom.xos", "цель есть — клауза строки 6 истинна")

        let probe1 = await stand.machine.prompts().first
        let prompt = try XCTUnwrap(probe1)
        try await stand.machine.answer(promptId: prompt.promptId, .skip, now: now)
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped, "строка 4 победила")
        await stand.machine.stop()
    }

    // MARK: - К46 (инв. 2, вторая половина: тотальность)

    /// Вид 1: вход, не названный ни одной строкой §7 для этого состояния, состояния НЕ
    /// МЕНЯЕТ и ошибки НЕ ДАЁТ — ни `throw`, ни падения, ни publish в `changes()`.
    ///
    /// Перебор идёт по трём достижимым в части A состояниям из девяти: `recording`,
    /// `stopping`, `processing` она не заводит ни одним входом, а `ready` и `failed` — часть
    /// B. Терминальное `skipped` покрыто К5.
    func test_k46_kind1_unnamedInputsChangeNothingInEveryReachableState() async throws {
        let states: [StateVector] = [
            StateVector(name: "scheduled", offset: -900, expected: .scheduled),
            StateVector(name: "armed", offset: -300, expected: .armed),
            StateVector(name: "awaitingSignal", offset: 60, expected: .awaitingSignal)
        ]

        for state in states {
            let name = state.name
            let offset = state.offset
            let expected = state.expected
            let stand = try bench()
            let event = try SessionMachineFixtures.event()
            stand.seed(event)
            let now = moment.addingTimeInterval(offset)

            let stream = stand.machine.changes()
            await stand.machine.start(now: now)
            await stand.machine.tick(now: now)

            stand.capture.emit(.levels(CaptureLevels(mic: 0.5, system: 0.2)))
            stand.capture.emit(.paused(atMs: 10))
            stand.queue.emit(.submitted(jobId: UUID(), type: .transcode))
            stand.queue.emit(.progressed(jobId: UUID(), fraction: 0.5))
            stand.power.emit(.screensDidSleep)
            stand.power.emit(.powerSourceChanged(.battery))
            await stand.awaitDelivery(6)
            await stand.machine.tick(now: now)

            let probe2 = await stand.machine.sessions().first?.state
            XCTAssertEqual(probe2, expected, "состояние \(name) не изменилось")

            // Ни одного publish сверх заведения: следующим в потоке идёт сторожевой переход.
            try await stand.machine.skip(meetingId: event.id, now: now)
            let changes = await collect(stream, count: 2)
            XCTAssertEqual(
                changes.compactMap { $0.session?.state },
                [expected, .skipped],
                "между заведением и сторожевым переходом поток молчал"
            )
            await stand.machine.stop()
        }
    }

    /// Вид 2: `start(now:)` на всяком содержимом хранилища — СЧЁТ ЗАВЕДЕНИЙ ВНЕ ТАБЛИЦЫ.
    ///
    /// **ВЕКТОР ПЕРЕПИСАН ЧАСТЬЮ C, И ЭТО НЕ ПРАВКА ПУНКТА, А ЕГО ИСПОЛНЕНИЕ.** Прежняя
    /// редакция этого теста требовала, чтобы `start(now:)` не заводил НИ ОДНОЙ сессии, и
    /// говорила об этом прямо: «часть A сессий вне таблицы не заводит ни одной —
    /// восстановление §10 есть часть C задачи». То есть счёт у неё был **ноль**, тогда как
    /// К46 требует **двух** и запрещает третий; на частях A и B пункт был частичным, и
    /// приёмка [MEE-300](https://linear.app/easypto/issue/MEE-300) назвала его таким с
    /// адресом части C. Здесь он закрывается.
    ///
    /// **Два способа — и оба в перечне А §10:** вход в `processing` и вход в `failed`.
    /// Заведение по §9.1 (строки 1, 1а, 1б) заведением ВНЕ таблицы не является, и перечень
    /// Б третьего способа не заводит — встрече в `recording` при нулевом числе записей
    /// машина ставит `failed` и сессии не заводит (К78, издание v7).
    ///
    /// Разбор каждого способа и оба различающих вектора — `SessionMachineRecoveryTests` и
    /// `SessionMachineRestoreTests`; здесь стоит СЧЁТ, ради которого пункт и написан.
    func test_k46_kind2_startOpensSessionsOutsideTheTableInExactlyTwoWays() async throws {
        for status in [
            MeetingStatus.scheduled, .armed, .awaitingSignal, .recording,
            .stopping, .processing, .ready, .failed, .skipped
        ] {
            let stand = try bench()
            let event = try SessionMachineFixtures.event()
            stand.seed(event, status: status)

            await stand.machine.start(now: moment)
            let live = await stand.machine.sessions()
            let openable: Set<MeetingStatus> = [.scheduled, .armed, .awaitingSignal]
            if openable.contains(status) {
                // Заведение по §9.1 — строками таблицы, а не вне её.
                XCTAssertEqual(live.count, 1, "\(status): заведено строкой 1, 1а либо 1б")
            } else {
                XCTAssertTrue(live.isEmpty, "\(status): записей нет — заведений вне таблицы ноль")
            }
            await stand.machine.stop()
        }
    }

    /// Счёт заведений вне таблицы — РОВНО ДВА, и оба в перечне А: вход в `processing` и
    /// вход в `failed`. Третьего нет ни одного, и перебор показывает это отсутствием.
    func test_k46_kind2_theTwoOutsideTheTableEntriesAndNoThird() async throws {
        // Способ 1: `recover` удался — вход в `processing`.
        let first = try bench()
        let firstId = UUID()
        let goodManifest = try SessionMachineFixtures.manifest(recordingId: firstId, meetingId: nil)
        first.repositories.recordings.seed([
            RecordingRecord(manifest: goodManifest, status: .recording)
        ])
        first.capture.setRecoverManifest(goodManifest)
        await first.machine.start(now: moment)
        let opened = await first.machine.sessions()
        XCTAssertEqual(opened.first?.state, .processing, "способ 1 — вход в `processing`")
        await first.machine.stop()

        // Способ 2: `recover` бросил — вход в `failed`.
        let second = try bench()
        let secondId = UUID()
        let badManifest = try SessionMachineFixtures.manifest(recordingId: secondId, meetingId: nil)
        second.repositories.recordings.seed([
            RecordingRecord(manifest: badManifest, status: .recording)
        ])
        second.capture.failRecover(with: .recoveryFailed(
            directoryName: secondId.uuidString, message: "вектор"
        ))
        let stream = second.machine.changes()
        await second.machine.start(now: moment)
        let published = await collect(stream, count: 1)
        XCTAssertEqual(published.first?.session?.state, .failed, "способ 2 — вход в `failed`")
        await second.machine.stop()

        // Третьего нет: встреча в `recording` при НУЛЕВОМ числе записей — пара, которой
        // перебор по двум перечислениям не даёт, — даёт `failed` встрече и НИ ОДНОЙ сессии.
        let third = try bench()
        let event = try SessionMachineFixtures.event()
        third.seed(event, status: .recording)
        await third.machine.start(now: moment)
        let none = await third.machine.sessions()
        XCTAssertTrue(none.isEmpty, "третьего способа нет ни одного")
        XCTAssertEqual(third.meetings.storedRecords.first?.status, .failed, "и статус ложен")
        await third.machine.stop()
    }

    // MARK: - К86 («Поведение», порядок фаз в один `tick`)

    /// Вход построен так, что пришедший сигнал МЕНЯЕТ исход срока: без него строка 9
    /// уводит сессию в `skipped`, с ним — клауза «звучащей цели нет» ложна и срок решается
    /// уже на НОВОЙ цели. Реализация, проверяющая сроки прежде применения событий, красна.
    func test_k86_phasesRunInTheNamedOrderSoTheDeadlineSeesTheNewTarget() async throws {
        let grace = moment.addingTimeInterval(1200)

        // Контроль: без сигнала на том же `now` срок срабатывает.
        let control = try bench()
        let controlEvent = try SessionMachineFixtures.event()
        control.seed(controlEvent)
        await control.machine.tick(now: moment.addingTimeInterval(60))
        await control.machine.tick(now: grace)
        let probe4 = await control.machine.sessions().isEmpty
        XCTAssertTrue(probe4, "контроль: без цели строка 9 срабатывает")

        // Вектор: сигнал приходит между двумя `tick` и применяется В ТОМ ЖЕ `tick`, что срок.
        // ПОЛНЫМ ОТВЕТОМ (часть B): срок решается на новой цели, и побеждает строка 8 —
        // сессия уходит в `recording`. Часть A наблюдала это ослабленно, «не ушла в
        // `skipped`»: строки 8 у неё не было ни одной.
        let stand = try bench()
        let generated = try SessionMachineFixtures.event()
        stand.seed(generated)
        stand.allowCaptureStart()
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        stand.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: grace.addingTimeInterval(-10)))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: grace)

        let probe5 = await stand.machine.sessions().first
        let live = try XCTUnwrap(probe5)
        XCTAssertEqual(live.state, .recording, "срок решён на цели, пришедшей этим же `tick`")
        XCTAssertEqual(live.target?.appKey, "us.zoom.xos")
        await stand.machine.stop()
    }

    /// Вход, пришедший МЕЖДУ двумя `tick`, до `tick` состояния не меняет — кроме команд §3.1,
    /// исполняемых в момент вызова.
    func test_k86_arrivalsDoNothingUntilTheNextTickWhileCommandsActAtOnce() async throws {
        let stand = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        stand.calendar.emit(.deleted([event.id]))
        await stand.awaitDelivery(1)

        let probe6 = await stand.machine.sessions().first?.state
        XCTAssertEqual(probe6,
            .awaitingSignal,
            "удаление события до `tick` состояния не меняет"
        )
        try await stand.machine.skip(meetingId: event.id, now: moment.addingTimeInterval(70))
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped, "а команда исполнена в момент вызова")
        await stand.machine.stop()
    }
}
