//  Порядок строк, тотальность отображения и порядок фаз в один `tick` — К45, К46, К86.
//  MEE-298, часть A. Пункты плана MEE-288 §3, разделы Ж и Н, части 3/8 и 6/8.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineOrderTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

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
        XCTAssertEqual(
            SessionMachineRules.deadlineRow(
                state: .scheduled, deadlines: deadlines, eventGone: false, hasSoundingTarget: false,
                now: past
            ),
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
        let states: [(String, TimeInterval, MeetingStatus)] = [
            ("scheduled", -900, .scheduled),
            ("armed", -300, .armed),
            ("awaitingSignal", 60, .awaitingSignal)
        ]

        for (name, offset, expected) in states {
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

    /// Вид 2: `start(now:)` на всяком содержимом хранилища. Часть A сессий вне таблицы не
    /// заводит НИ ОДНОЙ — восстановление §10 есть часть C задачи, и «ровно два способа»
    /// проверяется там. Здесь проверяется ровно то, что верно сегодня: их ноль.
    func test_k46_kind2_startOpensNoSessionOutsideTheTableInThisPart() async throws {
        for status in [
            MeetingStatus.scheduled, .armed, .awaitingSignal, .recording,
            .stopping, .processing, .ready, .failed, .skipped
        ] {
            let stand = try bench()
            let event = try SessionMachineFixtures.event()
            stand.seed(event, status: status)

            await stand.machine.start(now: moment)
            let probe3 = await stand.machine.sessions().isEmpty
            XCTAssertTrue(probe3,
                "`start(now:)` при хранимом \(status) сессий не заводит"
            )
            await stand.machine.stop()
        }
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
        let stand = try bench()
        let generated = try SessionMachineFixtures.event()
            stand.seed(generated)
        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        stand.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: grace.addingTimeInterval(-10)))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: grace)

        let probe5 = await stand.machine.sessions().first
        let live = try XCTUnwrap(probe5)
        XCTAssertEqual(live.state, .awaitingSignal, "срок решён на цели, пришедшей этим же `tick`")
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
