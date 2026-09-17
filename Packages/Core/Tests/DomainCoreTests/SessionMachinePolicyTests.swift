//  Политики §8.1—§8.3 и что заводит §9.1 — К49, К51—К55, К75.
//  MEE-298, часть A. Пункты плана MEE-288 §3, разделы З и К, части 4/8 и 5/8.
//
//  Половины пунктов, требующие строк 6 и 8 («срабатывают только после `.record`»,
//  «строка 6 срабатывает до `e.start`»), здесь не подаются: этих строк в части A нет ни
//  одной, и вектор на них был бы красен на верной реализации. Названо строкой отчёта.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachinePolicyTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(
        policy: AppSettings.RecordingPolicy = .auto,
        armLead: Int = 600,
        grace: Int = 1200
    ) throws -> SessionMachineBench {
        SessionMachineBench(
            settings: SessionMachineFixtures.settings(policy: policy, armLead: armLead, grace: grace),
            weights: try SessionMachineFixtures.weights()
        )
    }

    // MARK: - К49 (§8.1)

    /// `armAt == e.start − armLeadSeconds` ПРИ ЛЮБОМ значении поля. Значения подаются
    /// отличные от умолчания 120 — 600 и 0, — и число «2 мин» в текстах машины не стоит
    /// константой (текстовая половина — `SessionMachineTextTests`).
    func test_k49_armAtFollowsTheSettingAndNotALiteral() async throws {
        // При `armLeadSeconds == 0` момент `armAt` совпадает с `e.start`, и в один `tick`
        // срабатывают строка 2, а следом строка 7: исход `awaitingSignal`, и это не поблажка
        // вектору, а порядок таблицы. Соотношений между настройками контракт не требует (§5.1).
        for (lead, expected) in [(600, MeetingStatus.armed), (0, .awaitingSignal)] {
            let stand = try bench(armLead: lead)
            let event = try SessionMachineFixtures.event()
            stand.seed(event)
            let armAt = event.start.addingTimeInterval(-TimeInterval(lead))

            await stand.machine.tick(now: armAt.addingTimeInterval(-1))
            let probe0 = await stand.machine.sessions().first?.state
            XCTAssertEqual(probe0,
                .scheduled,
                "за секунду до `armAt` при `armLeadSeconds` \(lead)"
            )

            await stand.machine.tick(now: armAt)
            let probe1 = await stand.machine.sessions().first?.state
            XCTAssertEqual(probe1,
                expected,
                "ровно в `armAt` при `armLeadSeconds` \(lead)"
            )
        }
    }

    // MARK: - К51 (§8.2, `.ask`)

    /// В момент `askAt` поднимается спрос `.recordThisMeeting` с `sessionId` этой сессии.
    /// Вход «сессия заведена позже `askAt`» здесь не подаётся намеренно — это другой объект
    /// и он заведён К93 (часть C).
    func test_k51_ask_raisesThePromptAtAskAtForASessionThatExistedEarlier() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-300))   // сессия существует
        let probe2 = await stand.machine.prompts().isEmpty
        XCTAssertTrue(probe2, "до `askAt` спроса нет")

        await stand.machine.tick(now: moment.addingTimeInterval(-90))    // askAt = T − 90
        let prompts = await stand.machine.prompts()
        XCTAssertEqual(prompts.count, 1)
        let probe3 = await stand.machine.sessions().first
        let live = try XCTUnwrap(probe3)
        XCTAssertEqual(prompts.first?.sessionId, live.sessionId)
        XCTAssertEqual(prompts.first?.kind, .recordThisMeeting)
        XCTAssertNil(prompts.first?.expiresAt)
    }

    /// Ответ `.skip` уводит в `skipped`; ответа нет — сессия живёт до `graceEndsAt` и
    /// уходит в `skipped` своим сроком.
    func test_k51_ask_skipAnswerAndSilenceBothEndInSkipped() async throws {
        let byAnswer = try bench(policy: .ask)
        let first = try SessionMachineFixtures.event()
        byAnswer.seed(first)
        await byAnswer.machine.tick(now: moment.addingTimeInterval(-90))
        let probe4 = await byAnswer.machine.prompts().first
        let prompt = try XCTUnwrap(probe4)
        try await byAnswer.machine.answer(promptId: prompt.promptId, .skip, now: moment.addingTimeInterval(-80))
        XCTAssertEqual(byAnswer.meetings.storedRecords.first?.status, .skipped)
        let probe5 = await byAnswer.machine.prompts().isEmpty
        XCTAssertTrue(probe5, "спрос снят вместе с ответом")

        let bySilence = try bench(policy: .ask)
        let second = try SessionMachineFixtures.event()
        bySilence.seed(second)
        await bySilence.machine.tick(now: moment.addingTimeInterval(-90))
        await bySilence.machine.tick(now: moment.addingTimeInterval(1199))
        let probe6 = await bySilence.machine.sessions().isEmpty
        XCTAssertFalse(probe6, "без ответа живёт до `graceEndsAt`")
        await bySilence.machine.tick(now: moment.addingTimeInterval(1200))
        let probe7 = await bySilence.machine.sessions().isEmpty
        XCTAssertTrue(probe7, "и уходит в `skipped` своим сроком")
    }

    // MARK: - К52 (§8.2, `.manual`)

    /// При `.manual` спрос не поднимается НИ РАЗУ, сколько бы сроков ни прошло; без команды
    /// сессия уходит в `skipped` по `graceEndsAt`. `.manual` — отказ от автоматики, а не её
    /// отсрочка: реализация, трактующая его как `.ask`, красна счётом спросов.
    func test_k52_manual_raisesNoPromptEverAndEndsSkipped() async throws {
        let stand = try bench(policy: .manual)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.start(now: moment.addingTimeInterval(-300))
        for offset in [-300.0, -90.0, 0.0, 600.0] {
            await stand.machine.tick(now: moment.addingTimeInterval(offset))
            let probe8 = await stand.machine.prompts().isEmpty
            XCTAssertTrue(probe8, "на смещении \(offset) спроса нет")
        }
        // Звучащая цель есть — и записи всё равно не начинает.
        stand.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(600)))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: moment.addingTimeInterval(600))
        let probe9 = await stand.machine.sessions().first?.state
        XCTAssertEqual(probe9, .awaitingSignal)
        let probe10 = await stand.machine.prompts().isEmpty
        XCTAssertTrue(probe10)

        await stand.machine.tick(now: moment.addingTimeInterval(1200))
        XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped)
        await stand.machine.stop()
    }

    // MARK: - К53 (§8.2, «спрос — выход, а не состояние»)

    /// При висящем спросе состояние сессии — `armed` либо `awaitingSignal`, десятого
    /// значения нет; сессия ПРОДОЛЖАЕТ СЧИТАТЬ СРОКИ и уходит в `skipped` по `graceEndsAt`;
    /// снимок не говорит, висит ли спрос.
    ///
    /// Клауза «десятого значения нет» зелена по построению и названа планом (§5, п. 1):
    /// перечисление объявлено чужим контрактом, и десятого не собралось бы ни у кого.
    func test_k53_aRaisedPromptIsAnOutputAndDeadlinesKeepRunning() async throws {
        let stand = try bench(policy: .ask)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)

        await stand.machine.tick(now: moment.addingTimeInterval(-90))
        let probe11 = await stand.machine.sessions().first?.state
        XCTAssertEqual(probe11, .armed, "спрос висит, состояние `armed`")
        let probe12 = await stand.machine.prompts().count
        XCTAssertEqual(probe12, 1)

        await stand.machine.tick(now: moment.addingTimeInterval(60))
        let probe13 = await stand.machine.sessions().first?.state
        XCTAssertEqual(probe13,
            .awaitingSignal,
            "срок `e.start` прошёл при висящем спросе"
        )
        let probe14 = await stand.machine.prompts().count
        XCTAssertEqual(probe14, 1, "спрос тот же и не поднимался заново")

        await stand.machine.tick(now: moment.addingTimeInterval(1200))
        let probe15 = await stand.machine.sessions().isEmpty
        XCTAssertTrue(probe15, "и `graceEndsAt` тоже")
    }

    // MARK: - К55 (§8.3)

    /// «Сигнала нет» значит «нет ЗВУЧАЩЕЙ ЦЕЛИ», а не «пуст набор актуальных сигналов».
    /// Вход (б) держит набор непустым намеренно: реализация по отвергнутому чтению провалит
    /// ровно его, и другого места, где два чтения различаются, в плане нет.
    func test_k55_graceReadsTheSoundingTargetNotTheSignalSet() async throws {
        let grace = moment.addingTimeInterval(1200)

        // (а) сигналов нет вовсе.
        let empty = try bench()
        let emptyEvent = try SessionMachineFixtures.event()
        empty.seed(emptyEvent)
        await empty.machine.tick(now: moment.addingTimeInterval(60))
        await empty.machine.tick(now: grace)
        let probe16 = await empty.machine.sessions().isEmpty
        XCTAssertTrue(probe16, "(а) → `skipped`")

        // (б) запущенный и молчащий клиент: набор НЕПУСТ, звучащей цели нет.
        let silent = try bench()
        let silentEvent = try SessionMachineFixtures.event()
        silent.seed(silentEvent)
        await silent.machine.start(now: moment.addingTimeInterval(60))
        await silent.machine.tick(now: moment.addingTimeInterval(60))
        silent.processes.emit(SessionMachineFixtures.signal(
            kind: .clientRunning, weight: 0.4, appKey: "us.zoom.xos",
            observedAt: grace.addingTimeInterval(-10), pid: 701))
        silent.processes.emit(SessionMachineFixtures.signal(
            kind: .microphoneInUse, weight: 0.4, appKey: nil,
            observedAt: grace.addingTimeInterval(-10), pid: 702))
        await silent.awaitDelivery(2)
        await silent.machine.tick(now: grace)
        let probe17 = await silent.machine.sessions().isEmpty
        XCTAssertTrue(probe17, "(б) → `skipped`, хотя набор непуст")
        await silent.machine.stop()

        // (в) актуальный `clientAudioOutput` с группой.
        let sounding = try bench()
        let soundingEvent = try SessionMachineFixtures.event()
        sounding.seed(soundingEvent)
        await sounding.machine.start(now: moment.addingTimeInterval(60))
        await sounding.machine.tick(now: moment.addingTimeInterval(60))
        sounding.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: grace.addingTimeInterval(-10)))
        await sounding.awaitDelivery(1)
        await sounding.machine.tick(now: grace)
        let probe18 = await sounding.machine.sessions().isEmpty
        XCTAssertFalse(probe18, "(в) → не уходит")
        await sounding.machine.stop()
    }

    // MARK: - К75 (§9.1)

    /// События на весь день сессий не порождают; отменённые не порождают; ОТСУТСТВИЕ
    /// `conference` заведению НЕ МЕШАЕТ — ссылка на созвон живёт и в `bodyText`, и в
    /// `location`, а запись всё равно требует звучащей цели.
    func test_k75_allDayAndCancelledOpenNothingWhileAMissingConferenceDoesNotBlock() async throws {
        let allDay = try bench()
        allDay.seed(MeetingEventFixtures.allDayMoscow)
        await allDay.machine.tick(now: MeetingEventFixtures.allDayMoscow.start.addingTimeInterval(-900))
        let probe19 = await allDay.machine.sessions().isEmpty
        XCTAssertTrue(probe19, "событие на весь день сессии не порождает")

        let cancelled = try bench()
        let cancelledEvent = try SessionMachineFixtures.event(isCancelled: true)
        cancelled.seed(cancelledEvent)
        await cancelled.machine.tick(now: moment.addingTimeInterval(-900))
        let probe20 = await cancelled.machine.sessions().isEmpty
        XCTAssertTrue(probe20, "отменённое не порождает")

        let bare = try bench()
        let bareEvent = try SessionMachineFixtures.event(provider: nil)
        bare.seed(bareEvent)
        await bare.machine.tick(now: moment.addingTimeInterval(-900))
        let probe21 = await bare.machine.sessions().first?.state
        XCTAssertEqual(probe21,
            .scheduled,
            "отсутствие `conference` заведению не мешает"
        )
    }
}
