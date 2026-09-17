//  ПЕРЕПРОВЕРКА ШВА A/B, часть третья: строки 6 и 8 в пунктах, закрытых частью A
//  различающей половиной, — К35, К37, К49, К51.
//  MEE-300, часть B, §4 постановки.
//
//  Эти четыре пункта часть A закрыла ровно наполовину: их полный ответ называет
//  `recording`, а строк 6 и 8 у неё не было ни одной, и вектор на полный ответ был бы
//  КРАСЕН НА ВЕРНОЙ реализации. Здесь поданы вторые половины — и вместе с ними три входа,
//  на которых ответ сменило издание C-018 v5 (клауза строки 9 читает три причины, а не одну).
//
//  Файл отдельный ещё и по механическому доводу: линт считает тело типа длиннее двухсот
//  пятидесяти строк нарушением, а оба файла-донора к нему подошли вплотную.

import Foundation
import XCTest
@testable import DomainCore
import DomainTestKit

final class SessionMachineSeamRowsTests: XCTestCase {

    private let moment = SessionMachineFixtures.start

    private func bench(
        policy: AppSettings.RecordingPolicy = .auto,
        armLead: Int = 600
    ) throws -> (SessionMachineBench, AppSettings) {
        let settings = SessionMachineFixtures.settings(policy: policy, armLead: armLead)
        return (
            SessionMachineBench(settings: settings, weights: try SessionMachineFixtures.weights()),
            settings
        )
    }

    // MARK: - К35 (строка 7 уступает строке 6)

    /// Вторая половина пункта, ПОЛНЫМ ОТВЕТОМ (часть B): при наличии цели и разрешающей
    /// политике раньше строки 7 срабатывает СТРОКА 6, и сессия уходит в `recording`, а не в
    /// `awaitingSignal`. Реализация, читающая сроковые строки прежде сигнальных, зелена на
    /// трёх векторах без цели и красна ровно здесь — она теряет начало созвона.
    func test_k35_row7_yieldsToRow6WhenATargetIsPresent() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()

        await stand.machine.start(now: moment.addingTimeInterval(-300))
        await stand.machine.tick(now: moment.addingTimeInterval(-300))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(30)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(30))   // now ≥ e.start

        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "строка 6 стоит раньше строки 7 и побеждает")
        await stand.machine.stop()
    }

    // MARK: - К37 (строка 9 под изданием v5)

    /// Различающий по цели, ПОЛНЫМ ОТВЕТОМ (часть B): при звучащей цели и политике, которая
    /// её отдаёт, строка 9 в момент `graceEndsAt` не срабатывает — раньше побеждает строка 8,
    /// и сессия уходит в `recording`. Часть A наблюдала здесь только «не ушла в `skipped`»:
    /// строки 8 у неё не было, и полный ответ был бы красен на верной реализации.
    func test_k37_row9_yieldsToRow8WhileThePolicyGivesTheTarget() async throws {
        let (stand, _) = try bench()
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()

        await stand.machine.start(now: moment.addingTimeInterval(60))
        await stand.machine.tick(now: moment.addingTimeInterval(60))
        stand.processes.emit(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(1180)
        ))
        await stand.awaitDelivery(1)
        await stand.machine.tick(now: moment.addingTimeInterval(1200))

        let probe7 = await stand.machine.sessions().first
        let live = try XCTUnwrap(probe7)
        XCTAssertEqual(live.state, .recording, "в `skipped` не ушла — ушла в `recording` строкой 8")
        XCTAssertEqual(live.target?.appKey, "us.zoom.xos")
        await stand.machine.stop()
    }

    /// ТРИ ВХОДА, НА КОТОРЫХ ОТВЕТ СМЕНИЛСЯ ИЗДАНИЕМ v5, и два из них до неё не были
    /// покрыты ничем. Клауза строки 9 читает не одну причину, а три: цели нет; цель есть и
    /// занята (§7.1); цель есть и не отдана политикой (§8.2). При `.manual` и при `.ask`
    /// без ответа сессия со ЗВУЧАЩЕЙ И АКТУАЛЬНОЙ целью обязана уйти в `skipped` в момент
    /// `graceEndsAt`, а не висеть в `awaitingSignal` навсегда.
    func test_k37_row9_firesOnATargetThePolicyDidNotGive() async throws {
        for policy in [AppSettings.RecordingPolicy.manual, .ask] {
            let (stand, _) = try bench(policy: policy)
            let event = try SessionMachineFixtures.event()
            stand.seed(event)
            stand.allowCaptureStart()

            await stand.machine.start(now: moment.addingTimeInterval(60))
            await stand.machine.tick(now: moment.addingTimeInterval(60))
            stand.processes.emit(SessionMachineFixtures.audioOutput(
                appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(1180)
            ))
            await stand.awaitDelivery(1)

            await stand.machine.tick(now: moment.addingTimeInterval(1199))
            let before = await stand.machine.sessions().first
            XCTAssertEqual(try XCTUnwrap(before).state, .awaitingSignal, "\(policy): до срока живёт")

            await stand.machine.tick(now: moment.addingTimeInterval(1200))
            let leftAtGrace = await stand.machine.sessions()
            XCTAssertTrue(leftAtGrace.isEmpty, "\(policy): в срок уходит в `skipped`")
            XCTAssertEqual(stand.meetings.storedRecords.first?.status, .skipped)
            await stand.machine.stop()
        }
    }

    // MARK: - К49 (§8.1, вторая половина) и К51 (§8.2, `.ask`)

    /// Вторая половина К49, ПОЛНЫМ ОТВЕТОМ (часть B): с момента `armAt` сессия не только
    /// наблюдает и считает оценку, но и ВПРАВЕ ЗАПИСАТЬ — строка 6 срабатывает до `e.start`.
    /// Значение настройки подаётся отличным от умолчания 120, и ранний вход идёт по нему.
    func test_k49_theArmedSessionMayAlreadyRecordBeforeTheEventStarts() async throws {
        let (stand, _) = try bench(armLead: 600)
        let event = try SessionMachineFixtures.event()
        stand.seed(event)
        stand.allowCaptureStart()

        await stand.machine.start(now: moment.addingTimeInterval(-500))
        await stand.machine.tick(now: moment.addingTimeInterval(-500))
        let armedState = await stand.machine.sessions().first?.state
        XCTAssertEqual(armedState, .armed, "взведена по настройке")

        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(-500)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(-500))
        let live = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(live.state, .recording, "и записывает за 500 с до начала события")
        await stand.machine.stop()
    }

    /// ПОЛНЫМ ОТВЕТОМ (часть B): при `.ask` строки 6 и 8 срабатывают ТОЛЬКО ПОСЛЕ ответа
    /// `.record`. До ответа наличие звучащей цели записи не начинает; после — начинает.
    /// Реализация, начинающая запись по появлению цели («цель есть — человек в созвоне,
    /// спросим потом»), зелена на ветви `.record` и красна на ветвях `.skip` и «нет ответа».
    func test_k51_ask_rows6And8FireOnlyAfterTheRecordAnswer() async throws {
        let (stand, _) = try bench(policy: .ask)
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
        XCTAssertEqual(before.state, .awaitingSignal, "до ответа цель записи не начинает")
        XCTAssertEqual(before.target?.appKey, "us.zoom.xos", "хотя цель есть")

        let prompt = try unwrap(await stand.machine.prompts().first)
        try await stand.machine.answer(promptId: prompt.promptId, .record, now: moment.addingTimeInterval(70))
        await stand.deliver(SessionMachineFixtures.audioOutput(
            appKey: "us.zoom.xos", observedAt: moment.addingTimeInterval(70)
        ))
        await stand.machine.tick(now: moment.addingTimeInterval(70))
        let after = try unwrap(await stand.machine.sessions().first)
        XCTAssertEqual(after.state, .recording, "после `.record` строка 8 срабатывает")
        await stand.machine.stop()
    }
}
